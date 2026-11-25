// Experimental STK1160 audio reader: preserve half-stereo-frame USB boundaries.
// macOS needs administrator authorization to detach Apple's owning USB driver.
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#define TRANSFERS 16
#define PACKETS 32
static volatile sig_atomic_t interrupted;
static void stop_capture(int sig) { (void)sig; interrupted=1; }
static double now(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9; }
typedef struct {
    FILE *file;
    uint64_t bytes,packets,partial_packets,errors,zero_packets;
    int active,stopping,failed;
    unsigned char carry[4];size_t carried;
} Capture;
// Retain incomplete stereo frames across packet boundaries, without padding or
// deleting valid 16-bit samples. Equivalent byte continuity to Linux ALIGN_TRANSFER.
static int append(Capture *c,const unsigned char *p,size_t n) {
    if(n%2){c->errors++;c->failed=1;return -1;}
    if(n%4)c->partial_packets++;
    if(c->carried){size_t take=4-c->carried;if(take>n)take=n;memcpy(c->carry+c->carried,p,take);c->carried+=take;p+=take;n-=take;
        if(c->carried==4){if(fwrite(c->carry,1,4,c->file)!=4)return -1;c->bytes+=4;c->carried=0;}}
    size_t full=n/4*4;
    if(full){if(fwrite(p,1,full,c->file)!=full)return -1;c->bytes+=full;}
    if(n>full){memcpy(c->carry,p+full,n-full);c->carried=n-full;}
    return 0;
}
static void completed(struct libusb_transfer *transfer) {
    Capture *c=transfer->user_data;c->active--;
    if(transfer->status==LIBUSB_TRANSFER_CANCELLED)return;
    if(transfer->status!=LIBUSB_TRANSFER_COMPLETED){c->errors++;c->failed=1;return;}
    for(int i=0;i<transfer->num_iso_packets;i++) {
        struct libusb_iso_packet_descriptor *p=&transfer->iso_packet_desc[i];c->packets++;
        if(p->status!=LIBUSB_TRANSFER_COMPLETED){c->errors++;c->failed=1;break;}
        if(!p->actual_length)c->zero_packets++;
        if(append(c,libusb_get_iso_packet_buffer_simple(transfer,i),p->actual_length)){c->failed=1;break;}
    }
    if(!c->stopping && !c->failed && !interrupted){int e=libusb_submit_transfer(transfer);if(e){c->errors++;c->failed=1;}else c->active++;}
}
static int reg_write(libusb_device_handle *dev,uint16_t reg,uint8_t value) {
    int e=libusb_control_transfer(dev,0x40,1,value,reg,NULL,0,1000);return e<0?e:0;
}
static int codec_write(libusb_device_handle *dev,uint8_t reg,uint16_t value) {
    int e=reg_write(dev,0x504,reg);if(!e)e=reg_write(dev,0x502,value&255);if(!e)e=reg_write(dev,0x503,value>>8);if(!e)e=reg_write(dev,0x500,0x8c);
    for(int i=0;!e && i<100;i++){unsigned char state=0;e=libusb_control_transfer(dev,0xc0,0,0,0x500,&state,1,1000);if(e<0)return e;if(!(state&6))return 0;e=0;usleep(1000);}return e?e:LIBUSB_ERROR_TIMEOUT;
}
static int self_test(void) {
    Capture c={0};c.file=tmpfile();if(!c.file)return 1;
    unsigned char data[576],readback[576];for(unsigned i=0;i<sizeof(data);i++)data[i]=(unsigned char)i;
    if(append(&c,data,190)||append(&c,data+190,194)||append(&c,data+384,192))return 1;
    rewind(c.file);size_t n=fread(readback,1,sizeof(readback),c.file);fclose(c.file);
    if(n!=sizeof(data)||memcmp(data,readback,n)||c.carried||c.partial_packets!=2)return 1;
    Capture shortPackets={0};shortPackets.file=tmpfile();if(!shortPackets.file)return 1;
    if(append(&shortPackets,data,2)||append(&shortPackets,data+2,0)||append(&shortPackets,data+2,2)||shortPackets.bytes!=4||shortPackets.carried)return 1;
    if(append(&shortPackets,data,1)!=-1||shortPackets.errors!=1)return 1;
    fclose(shortPackets.file);
    puts("Half-frame reconstruction, empty packets and odd-byte rejection passed");return 0;
}
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--self-test"))return self_test();
    int probe=argc==2&&!strcmp(argv[1],"--probe");
    if(!probe&&argc!=3&&!(argc==5&&!strcmp(argv[3],"--start-delay"))){fprintf(stderr,"Usage: ecv-usbaudio SECONDS NEW_OUTPUT.s16le [--start-delay SECONDS] | --probe | --self-test\n");return 2;}
    double seconds=0,delay=0;char *end=NULL;
    if(argc==5){delay=strtod(argv[4],&end);if(end==argv[4]||*end||!isfinite(delay)||delay<0||delay>30)return 2;}
    if(!probe){seconds=strtod(argv[1],&end);if(end==argv[1]||*end||!isfinite(seconds)||seconds<=0||seconds>120)return 2;}
    libusb_context *context=NULL;libusb_device_handle *dev=NULL;libusb_device **list=NULL;
    int error=libusb_init(&context);if(error)return 1;
    ssize_t count=libusb_get_device_list(context,&list);int found=0;
    for(ssize_t i=0;i<count;i++){struct libusb_device_descriptor d;if(!libusb_get_device_descriptor(list[i],&d)&&d.idVendor==0x05e1&&d.idProduct==0x0408){found++;if(found==1)error=libusb_open(list[i],&dev);}}
    libusb_free_device_list(list,1);
    if(found!=1||!dev){fprintf(stderr,"Expected exactly one STK1160, found %d (%s)\n",found,libusb_error_name(error));if(dev)libusb_close(dev);libusb_exit(context);return 1;}
    struct libusb_config_descriptor *config=NULL;
    error=libusb_get_active_config_descriptor(libusb_get_device(dev),&config);
    int iface=-1,alt=0,packetSize=0;unsigned char endpoint=0;
    if(!error)for(unsigned i=0;i<config->bNumInterfaces;i++)for(int a=0;a<config->interface[i].num_altsetting;a++){
        const struct libusb_interface_descriptor *d=&config->interface[i].altsetting[a];
        if(d->bInterfaceClass!=1||d->bInterfaceSubClass!=2||!d->bNumEndpoints)continue;
        // Require USB Audio Type-I, stereo, 16-bit, discrete 48 kHz.
        int formatOK=0;
        for(int x=0;x+2<=d->extra_length;){const unsigned char *p=d->extra+x;int len=p[0];if(len<2||x+len>d->extra_length)break;
            if(len>=11&&p[1]==0x24&&p[2]==2&&p[3]==1&&p[4]==2&&p[5]==2&&p[6]==16&&p[7]>0)
                for(int f=0;f<p[7]&&8+3*f+3<=len;f++){const unsigned char *rate=p+8+3*f;if((rate[0]|rate[1]<<8|rate[2]<<16)==48000)formatOK=1;}
            x+=len;
        }
        for(unsigned e=0;formatOK&&e<d->bNumEndpoints;e++){const struct libusb_endpoint_descriptor *p=&d->endpoint[e];
            if((p->bmAttributes&3)==1&&(p->bEndpointAddress&0x80)){iface=d->bInterfaceNumber;alt=d->bAlternateSetting;endpoint=p->bEndpointAddress;packetSize=p->wMaxPacketSize&0x7ff;}
        }
    }
    if(config)libusb_free_config_descriptor(config);
    fprintf(stderr,"STK1160 audio interface=%d alternate=%d endpoint=0x%02x packet_size=%d\n",iface,alt,endpoint,packetSize);
    if(probe||iface<0||packetSize<192){libusb_close(dev);libusb_exit(context);return iface>=0?0:1;}
    // Do not attempt to work around OS authorization; detaching is privileged.
    if(geteuid()!=0){fprintf(stderr,"Administrator authorization is required to detach Apple's USB audio driver for this test. No device changes made.\n");libusb_close(dev);libusb_exit(context);return 3;}
    int fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0){perror("output");libusb_close(dev);libusb_exit(context);return 2;}
    Capture c={0};c.file=fdopen(fd,"wb");if(!c.file){close(fd);libusb_close(dev);libusb_exit(context);return 1;}
    signal(SIGINT,stop_capture);signal(SIGTERM,stop_capture);
    double captureStart=0;
    int detached=0,claimed=0;
    struct libusb_transfer *transfers[TRANSFERS]={0};
    fprintf(stderr,"Detaching Apple USB audio driver\n");error=libusb_detach_kernel_driver(dev,iface);fprintf(stderr,"detach: %s\n",libusb_error_name(error));if(error)goto cleanup;detached=1;
    error=libusb_claim_interface(dev,iface);fprintf(stderr,"claim: %s\n",libusb_error_name(error));if(error)goto cleanup;claimed=1;
    // Set up only the audio codec, leaving the video registers untouched.
    error=reg_write(dev,0x500,0x94);if(!error)error=reg_write(dev,0x500,0x8c);
    if(!error)error=reg_write(dev,0x506,1);if(!error)error=reg_write(dev,0x507,0);
    if(!error)error=codec_write(dev,0x1a,0x0404);if(!error)error=codec_write(dev,0x10,0x0808);if(!error)error=codec_write(dev,0x1c,0x0808);
    fprintf(stderr,"codec initialization: %s\n",libusb_error_name(error));if(error)goto cleanup;
    if(delay){fprintf(stderr,"Ready for video initialization; delaying audio %.1f seconds\n",delay);fflush(stderr);usleep((useconds_t)(delay*1e6));}
    error=libusb_set_interface_alt_setting(dev,iface,alt);fprintf(stderr,"alternate setting: %s\n",libusb_error_name(error));if(error)goto cleanup;
    if(interrupted)goto cleanup;
    captureStart=now();
    for(int i=0;i<TRANSFERS;i++){
        transfers[i]=libusb_alloc_transfer(PACKETS);unsigned char *buffer=malloc(PACKETS*packetSize);
        if(!transfers[i]||!buffer){free(buffer);error=LIBUSB_ERROR_NO_MEM;break;}
        libusb_fill_iso_transfer(transfers[i],dev,endpoint,buffer,PACKETS*packetSize,PACKETS,completed,&c,0);
        libusb_set_iso_packet_lengths(transfers[i],packetSize);
        error=libusb_submit_transfer(transfers[i]);if(error)break;c.active++;
    }
    double start=now();
    while(!error&&!c.failed&&!interrupted&&now()-start<seconds){struct timeval timeout={0,50000};error=libusb_handle_events_timeout(context,&timeout);if(error==LIBUSB_ERROR_INTERRUPTED)error=0;}
    c.stopping=1;
    for(int i=0;i<TRANSFERS;i++)if(transfers[i])libusb_cancel_transfer(transfers[i]);
    while(c.active){struct timeval timeout={0,100000};int e=libusb_handle_events_timeout(context,&timeout);if(e&&e!=LIBUSB_ERROR_INTERRUPTED){error=e;usleep(1000);}}
    if(delay){fprintf(stderr,"Audio capture complete; twenty-second video shutdown grace\n");fflush(stderr);usleep(20000000);}
cleanup:
    for(int i=0;i<TRANSFERS;i++)if(transfers[i]){free(transfers[i]->buffer);libusb_free_transfer(transfers[i]);}
    if(claimed){libusb_set_interface_alt_setting(dev,iface,0);libusb_release_interface(dev,iface);}
    if(detached){int restore=libusb_attach_kernel_driver(dev,iface);if(restore){fprintf(stderr,"Driver restore failed: %s\n",libusb_error_name(restore));error=restore;}}
    if(fclose(c.file))c.failed=1;
    const char *uid=getenv("SUDO_UID"),*gid=getenv("SUDO_GID");if(uid&&gid)chown(argv[2],(uid_t)strtoul(uid,NULL,10),(gid_t)strtoul(gid,NULL,10));
    printf("{\"start_monotonic\":%.9f,\"backend\":\"usb\",\"sample_rate\":48000,\"channels\":2,\"bytes\":%llu,\"sample_seconds\":%.6f,\"packets\":%llu,\"partial_packets\":%llu,\"empty_packets\":%llu,\"packet_errors\":%llu,\"trailing_bytes\":%zu,\"usb_error\":%d,\"write_error\":%s}\n",captureStart,(unsigned long long)c.bytes,c.bytes/192000.0,(unsigned long long)c.packets,(unsigned long long)c.partial_packets,(unsigned long long)c.zero_packets,(unsigned long long)c.errors,c.carried,error,c.failed?"true":"false");
    libusb_close(dev);libusb_exit(context);return error||c.failed||!c.bytes?1:0;
}
