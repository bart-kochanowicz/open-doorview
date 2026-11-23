/*
 * first-snap: a measurement prototype, not a Majestic replacement. It starts the camera pipeline of the GK7202V300
 * (sensor, ISP, VI, VPSS, JPEG encoder) the way OpenIPC's divinus streamer does for this chip family, writes the
 * first N JPEG pictures to files and prints, for every step and every picture, the time since boot (the clock of
 * the kernel log) and the exposure state of the ISP. It answers one question: how soon after its start can a
 * program without Majestic's other work hand over a usable picture?
 *
 * NOT RUN ON A CAMERA YET. Run it from RAM (/tmp) with Majestic stopped; it writes nothing to flash.
 *
 * Usage: first-snap [-n pictures] [-w width] [-h height] [-q quality] [-f fps] [-o prefix] [-e exposure-file]
 *   -e reads "exptime again dgain ispdgain exposure lines500ms iso" (one line, as printed after "state:" by an
 *   earlier run) and gives it to the sensor library as the initial exposure, so that the automatic exposure starts
 *   near the right value instead of from its default.
 *
 * Run it as LD_LIBRARY_PATH=/etc/doorview-lcd ./first-snap (see the comment above "libraries" below).
 */
#include <asm/unistd.h>
#include <linux/ioctl.h>
#include <stddef.h>

#include "gk_api_ae.h"
#include "gk_api_awb.h"
#include "gk_api_isp.h"
#include "gk_api_sys.h"
#include "gk_api_vb.h"
#include "gk_api_venc.h"
#include "gk_api_vi.h"
#include "gk_api_vpss.h"
#include "mipi.h"
#include "sns_ctrl.h"

/* The GC2053 as /etc/sensors/gc2053_i2c_1080p.ini describes it (the file Majestic uses on this camera). */
#define SENSOR_LIBRARY "/usr/lib/sensors/libsns_gc2053.so"
#define SENSOR_OBJECT "stSnsGc2053Obj"
#define SENSOR_WIDTH 1920
#define SENSOR_HEIGHT 1080
#define SENSOR_I2C_BUS 0

#define VI_DEVICE 0
#define VI_PIPE_ID 0
#define VI_CHANNEL 0
#define VPSS_GROUP 0
#define VPSS_CHANNEL 0
#define VENC_CHANNEL 0
#define MAX_PICTURES 30
#define MAX_PACKS 8
#define PICTURE_TIMEOUT_MS 3000

/* ---- libc: musl, declared here because the build has no musl headers (see tools/build-in-container.sh) ---- */

extern void *dlopen(const char *path, int flags);
extern void *dlsym(void *handle, const char *name);
extern char *dlerror(void);
extern int pthread_create(unsigned long *thread, const void *attributes, void *(*start)(void *), void *argument);
extern int pthread_join(unsigned long thread, void **result);
extern void *memset(void *, int, size_t);
extern void *memcpy(void *, const void *, size_t);
extern long syscall(long number, ...);

#define RTLD_LAZY 1
#define RTLD_GLOBAL 256
#define O_RDONLY 0
#define O_RDWR 2
#define O_WRONLY_CREAT_TRUNC (01 | 0100 | 01000)
#define CLOCK_BOOTTIME 7
#define POLLIN 1

/* The vendor libraries were built for a 32-bit off_t and pass the offset as one word; musl's mmap takes 64 bits. */
void *mmap(void *address, size_t length, int protection, int flags, int fd, unsigned long offset)
{
    return (void *)syscall(__NR_mmap2, address, length, protection, flags, fd, offset >> 12);
}

struct timespec32 {
    long seconds;
    long nanoseconds;
};

struct pollfd32 {
    int fd;
    short events;
    short revents;
};

/* Milliseconds since boot, the clock of the kernel log ("[    5.123456]"), so the steps line up with dmesg. */
static unsigned long boot_ms(void)
{
    struct timespec32 now;
    syscall(__NR_clock_gettime, CLOCK_BOOTTIME, &now);
    return (unsigned long)now.seconds * 1000 + (unsigned long)now.nanoseconds / 1000000;
}

static unsigned long started_ms;

/* Output through write(2) only: once the vendor system is initialised, musl's stdio crashes (a NULL dereference in
 * vfprintf, observed on the unit; vo-live-30 avoids stdio too). */
struct line {
    char text[320];
    unsigned int length;
};

static void add_text(struct line *line, const char *text)
{
    while (*text && line->length < sizeof(line->text) - 1)
        line->text[line->length++] = *text++;
}

static void add_number(struct line *line, unsigned long value, unsigned int base, unsigned int width)
{
    char digits[12];
    unsigned int count = 0;
    do {
        digits[count++] = "0123456789abcdef"[value % base];
        value /= base;
    } while (value && count < sizeof(digits));
    while (count < width && count < sizeof(digits))
        digits[count++] = '0';
    while (count && line->length < sizeof(line->text) - 1)
        line->text[line->length++] = digits[--count];
}

static void add_signed(struct line *line, long value)
{
    if (value < 0) {
        add_text(line, "-");
        value = -value;
    }
    add_number(line, (unsigned long)value, 10, 0);
}

static void add_field(struct line *line, const char *name, unsigned long value)
{
    add_text(line, name);
    add_number(line, value, 10, 0);
}

static void finish(struct line *line, int fd)
{
    line->text[line->length++] = '\n';
    syscall(__NR_write, fd, line->text, line->length);
}

/* The vendor libraries print through these; Majestic defines printf and puts for them too. Only the format text is
 * written, without its arguments. */
static void write_text(int fd, const char *text)
{
    size_t length = 0;
    while (text[length])
        ++length;
    syscall(__NR_write, fd, text, length);
}

int printf(const char *format, ...)
{
    write_text(1, format);
    return 0;
}

int fprintf(FILE *file, const char *format, ...)
{
    (void)file;
    write_text(2, format);
    return 0;
}

int puts(const char *text)
{
    write_text(1, text);
    write_text(1, "\n");
    return 0;
}

static void say(int fd, const char *first, const char *second)
{
    struct line line = {.length = 0};
    add_text(&line, first);
    add_text(&line, second);
    finish(&line, fd);
}

/* "<seconds since boot>.<ms> +<ms since start>ms " */
static void add_time(struct line *line)
{
    unsigned long now = boot_ms();
    add_number(line, now / 1000, 10, 0);
    add_text(line, ".");
    add_number(line, now % 1000, 10, 3);
    add_text(line, " +");
    add_number(line, now - started_ms, 10, 0);
    add_text(line, "ms ");
}

static void step(const char *name, long result)
{
    struct line line = {.length = 0};
    add_time(&line);
    add_text(&line, name);
    add_text(&line, ": 0x");
    add_number(&line, (unsigned long)result, 16, 0);
    finish(&line, 1);
}

/* ---- the vendor functions, looked up by name ---- */

#define VENDOR_FUNCTIONS(X) \
    X(GK_S32, GK_API_SYS_Init, (void)) \
    X(GK_S32, GK_API_SYS_Exit, (void)) \
    X(GK_S32, GK_API_SYS_Bind, (const MPP_CHN_S *, const MPP_CHN_S *)) \
    X(GK_S32, GK_API_SYS_UnBind, (const MPP_CHN_S *, const MPP_CHN_S *)) \
    X(GK_S32, GK_API_SYS_GetVIVPSSMode, (VI_VPSS_MODE_S *)) \
    X(GK_S32, GK_API_SYS_SetVIVPSSMode, (const VI_VPSS_MODE_S *)) \
    X(GK_S32, GK_API_VB_SetConfig, (const VB_CONFIG_S *)) \
    X(GK_S32, GK_API_VB_Init, (void)) \
    X(GK_S32, GK_API_VB_Exit, (void)) \
    X(GK_S32, GK_API_VI_SetDevAttr, (VI_DEV, const VI_DEV_ATTR_S *)) \
    X(GK_S32, GK_API_VI_EnableDev, (VI_DEV)) \
    X(GK_S32, GK_API_VI_DisableDev, (VI_DEV)) \
    X(GK_S32, GK_API_VI_SetDevBindPipe, (VI_DEV, const VI_DEV_BIND_PIPE_S *)) \
    X(GK_S32, GK_API_VI_CreatePipe, (VI_PIPE, const VI_PIPE_ATTR_S *)) \
    X(GK_S32, GK_API_VI_StartPipe, (VI_PIPE)) \
    X(GK_S32, GK_API_VI_StopPipe, (VI_PIPE)) \
    X(GK_S32, GK_API_VI_DestroyPipe, (VI_PIPE)) \
    X(GK_S32, GK_API_VI_SetChnAttr, (VI_PIPE, VI_CHN, const VI_CHN_ATTR_S *)) \
    X(GK_S32, GK_API_VI_EnableChn, (VI_PIPE, VI_CHN)) \
    X(GK_S32, GK_API_VI_DisableChn, (VI_PIPE, VI_CHN)) \
    X(GK_S32, GK_API_ISP_MemInit, (VI_PIPE)) \
    X(GK_S32, GK_API_ISP_SetPubAttr, (VI_PIPE, const ISP_PUB_ATTR_S *)) \
    X(GK_S32, GK_API_ISP_Init, (VI_PIPE)) \
    X(GK_S32, GK_API_ISP_Run, (VI_PIPE)) \
    X(GK_S32, GK_API_ISP_Exit, (VI_PIPE)) \
    X(GK_S32, GK_API_AE_Register, (VI_PIPE, ALG_LIB_S *)) \
    X(GK_S32, GK_API_AE_UnRegister, (VI_PIPE, ALG_LIB_S *)) \
    X(GK_S32, GK_API_AWB_Register, (VI_PIPE, ALG_LIB_S *)) \
    X(GK_S32, GK_API_AWB_UnRegister, (VI_PIPE, ALG_LIB_S *)) \
    X(GK_S32, GK_API_ISP_QueryExposureInfo, (VI_PIPE, ISP_EXP_INFO_S *)) \
    X(GK_S32, GK_API_VPSS_CreateGrp, (VPSS_GRP, const VPSS_GRP_ATTR_S *)) \
    X(GK_S32, GK_API_VPSS_StartGrp, (VPSS_GRP)) \
    X(GK_S32, GK_API_VPSS_StopGrp, (VPSS_GRP)) \
    X(GK_S32, GK_API_VPSS_DestroyGrp, (VPSS_GRP)) \
    X(GK_S32, GK_API_VPSS_SetChnAttr, (VPSS_GRP, VPSS_CHN, const VPSS_CHN_ATTR_S *)) \
    X(GK_S32, GK_API_VPSS_EnableChn, (VPSS_GRP, VPSS_CHN)) \
    X(GK_S32, GK_API_VPSS_DisableChn, (VPSS_GRP, VPSS_CHN)) \
    X(GK_S32, GK_API_VENC_CreateChn, (VENC_CHN, const VENC_CHN_ATTR_S *)) \
    X(GK_S32, GK_API_VENC_DestroyChn, (VENC_CHN)) \
    X(GK_S32, GK_API_VENC_GetJpegParam, (VENC_CHN, VENC_JPEG_PARAM_S *)) \
    X(GK_S32, GK_API_VENC_SetJpegParam, (VENC_CHN, const VENC_JPEG_PARAM_S *)) \
    X(GK_S32, GK_API_VENC_StartRecvFrame, (VENC_CHN, const VENC_RECV_PIC_PARAM_S *)) \
    X(GK_S32, GK_API_VENC_StopRecvFrame, (VENC_CHN)) \
    X(GK_S32, GK_API_VENC_QueryStatus, (VENC_CHN, VENC_CHN_STATUS_S *)) \
    X(GK_S32, GK_API_VENC_GetStream, (VENC_CHN, VENC_STREAM_S *, GK_S32)) \
    X(GK_S32, GK_API_VENC_ReleaseStream, (VENC_CHN, VENC_STREAM_S *)) \
    X(GK_S32, GK_API_VENC_GetFd, (VENC_CHN))

#define DECLARE(type, name, arguments) static type(*p_##name) arguments;
VENDOR_FUNCTIONS(DECLARE)

/* Only the sensor library is opened here. The other vendor libraries are linked as load-time dependencies, as
 * Majestic links them: they need each other in a cycle (libgk_isp and dehaze/drc/ldci) and through data
 * relocations, which musl resolves only when every library is loaded at once. Three uClibc symbols they use
 * (__ctype_b, __fgetc_unlocked, _stdlib_mb_cur_max) come from the compatibility library of stage 2, so the
 * program runs with LD_LIBRARY_PATH=/etc/doorview-lcd. */
static const char *const libraries[] = {SENSOR_LIBRARY};

static void *last_library;

static int load_vendor(void)
{
    for (size_t i = 0; i < sizeof(libraries) / sizeof(libraries[0]); ++i) {
        if (!(last_library = dlopen(libraries[i], RTLD_LAZY | RTLD_GLOBAL))) {
            say(2, "dlopen failed: ", dlerror());
            return 1;
        }
    }
#define LOOKUP(type, name, arguments) \
    if (!(p_##name = (type(*) arguments)dlsym(NULL, #name))) { \
        say(2, "missing ", #name); \
        return 1; \
    }
    VENDOR_FUNCTIONS(LOOKUP)
    return 0;
}

/* ---- the pipeline ---- */

static ISP_SNS_OBJ_S *sensor;
static ALG_LIB_S ae_library = {.s32Id = 0, .acLibName = ISP_AE_LIB_NAME};
static ALG_LIB_S awb_library = {.s32Id = 0, .acLibName = ISP_AWB_LIB_NAME};
static ISP_EXP_INFO_S exposure;

static int width = 1280, height = 720, quality = 55, fps = 30, pictures = 5;
static const char *prefix = "/tmp/first-snap";
static const char *exposure_file;

static GK_U32 align_up(GK_U32 value, GK_U32 alignment)
{
    return (value + alignment - 1) / alignment * alignment;
}

/* Two pools, sized as divinus does: raw Bayer frames from VI (offline VI), and YUV 4:2:0 frames for the encoder. */
static int configure_buffers(void)
{
    VB_CONFIG_S config;
    memset(&config, 0, sizeof(config));
    config.u32MaxPoolCnt = 2;
    config.astCommPool[0].u64BlkSize = align_up(align_up(SENSOR_WIDTH * 10, 8) / 8, 16) * SENSOR_HEIGHT;
    config.astCommPool[0].u32BlkCnt = 3;
    config.astCommPool[1].u64BlkSize = align_up(SENSOR_WIDTH, 16) * align_up(SENSOR_HEIGHT, 16) * 3 / 2 + 16 * SENSOR_HEIGHT * 3 / 2;
    config.astCommPool[1].u32BlkCnt = 2;
    p_GK_API_SYS_Exit();
    p_GK_API_VB_Exit();
    long result;
    if ((result = p_GK_API_VB_SetConfig(&config)) || (result = p_GK_API_VB_Init()) || (result = p_GK_API_SYS_Init())) {
        step("buffers and system", result);
        return 1;
    }
    step("buffers and system", 0);
    return 0;
}

static long mipi_ioctl(int fd, unsigned long request, void *argument)
{
    return syscall(__NR_ioctl, fd, request, argument);
}

/* The MIPI receiver and the sensor clock and reset, in divinus's order. */
static int configure_mipi(void)
{
    combo_dev_attr_t attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.devno = 0;
    attributes.input_mode = INPUT_MODE_MIPI;
    attributes.data_rate = MIPI_DATA_RATE_X1;
    attributes.img_rect.width = SENSOR_WIDTH;
    attributes.img_rect.height = SENSOR_HEIGHT;
    attributes.mipi_attr.input_data_type = DATA_TYPE_RAW_10BIT;
    attributes.mipi_attr.wdr_mode = MIPI_WDR_MODE_NONE;
    /* lane_id = 0|2|-1|-1 in the sensor file: two lanes. */
    attributes.mipi_attr.lane_id[0] = 0;
    attributes.mipi_attr.lane_id[1] = 2;
    attributes.mipi_attr.lane_id[2] = -1;
    attributes.mipi_attr.lane_id[3] = -1;

    int fd = (int)syscall(__NR_open, "/dev/mipi", O_RDWR, 0);
    if (fd < 0) {
        step("open /dev/mipi", fd);
        return 1;
    }
    lane_divide_mode_t lanes = LANE_DIVIDE_MODE_0;
    combo_dev_t device = 0;
    sns_clk_source_t clock = 0;
    sns_rst_source_t reset = 0;
    long result = mipi_ioctl(fd, MIPI_SET_HS_MODE, &lanes);
    result |= mipi_ioctl(fd, MIPI_ENABLE_MIPI_CLOCK, &device);
    result |= mipi_ioctl(fd, MIPI_RESET_MIPI, &device);
    result |= mipi_ioctl(fd, MIPI_ENABLE_SENSOR_CLOCK, &clock);
    result |= mipi_ioctl(fd, MIPI_RESET_SENSOR, &reset);
    result |= mipi_ioctl(fd, MIPI_SET_DEV_ATTR, &attributes);
    result |= mipi_ioctl(fd, MIPI_UNRESET_MIPI, &device);
    result |= mipi_ioctl(fd, MIPI_UNRESET_SENSOR, &reset);
    syscall(__NR_close, fd);
    step("mipi", result);
    return result != 0;
}

static int configure_vi(void)
{
    VI_VPSS_MODE_S mode;
    p_GK_API_SYS_GetVIVPSSMode(&mode);
    for (int i = 0; i < VI_MAX_PIPE_NUM; ++i)
        mode.aenMode[i] = VI_OFFLINE_VPSS_ONLINE;
    long result = p_GK_API_SYS_SetVIVPSSMode(&mode);
    if (result) {
        step("vi-vpss mode", result);
        return 1;
    }

    VI_DEV_ATTR_S device;
    memset(&device, 0, sizeof(device));
    device.enIntfMode = VI_MODE_MIPI;
    device.enWorkMode = VI_WORK_MODE_1Multiplex;
    device.au32ComponentMask[0] = 0xFFF00000;
    device.au32ComponentMask[1] = 0x0;
    device.enScanMode = VI_SCAN_PROGRESSIVE;
    for (unsigned i = 0; i < VI_MAX_ADCHN_NUM; ++i)
        device.as32AdChnId[i] = -1;
    device.enDataSeq = 2;
    device.stSynCfg.enVsync = VI_VSYNC_PULSE;
    device.stSynCfg.enVsyncNeg = 1;
    device.stSynCfg.enHsync = VI_HSYNC_VALID_SINGNAL;
    device.stSynCfg.enHsyncNeg = VI_HSYNC_NEG_HIGH;
    device.stSynCfg.enVsyncValid = VI_VSYNC_VALID_SINGAL;
    device.stSynCfg.enVsyncValidNeg = VI_VSYNC_VALID_NEG_HIGH;
    device.stSynCfg.stTimingBlank.u32HsyncAct = SENSOR_WIDTH;
    device.stSynCfg.stTimingBlank.u32VsyncVact = SENSOR_HEIGHT;
    device.enInputDataType = VI_DATA_TYPE_RGB;
    device.bDataReverse = GK_FALSE;
    device.stSize.u32Width = SENSOR_WIDTH;
    device.stSize.u32Height = SENSOR_HEIGHT;
    device.stBasAttr.stSacleAttr.stBasSize.u32Width = SENSOR_WIDTH;
    device.stBasAttr.stSacleAttr.stBasSize.u32Height = SENSOR_HEIGHT;
    device.stWDRAttr.enWDRMode = WDR_MODE_NONE;
    device.stWDRAttr.u32CacheLine = SENSOR_HEIGHT;
    device.enDataRate = DATA_RATE_X1;
    if ((result = p_GK_API_VI_SetDevAttr(VI_DEVICE, &device)) || (result = p_GK_API_VI_EnableDev(VI_DEVICE))) {
        step("vi device", result);
        return 1;
    }

    VI_DEV_BIND_PIPE_S bind;
    memset(&bind, 0, sizeof(bind));
    bind.u32Num = 1;
    bind.PipeId[0] = VI_PIPE_ID;
    VI_PIPE_ATTR_S pipe;
    memset(&pipe, 0, sizeof(pipe));
    pipe.enPipeBypassMode = VI_PIPE_BYPASS_NONE;
    pipe.u32MaxW = SENSOR_WIDTH;
    pipe.u32MaxH = SENSOR_HEIGHT;
    pipe.enPixFmt = PIXEL_FORMAT_RGB_BAYER_10BPP;
    pipe.enCompressMode = COMPRESS_MODE_NONE;
    pipe.enBitWidth = DATA_BITWIDTH_10;
    pipe.stNrAttr.enCompressMode = COMPRESS_MODE_NONE;
    pipe.bSharpenEn = GK_TRUE;
    pipe.stFrameRate.s32SrcFrameRate = -1;
    pipe.stFrameRate.s32DstFrameRate = -1;
    if ((result = p_GK_API_VI_SetDevBindPipe(VI_DEVICE, &bind)) || (result = p_GK_API_VI_CreatePipe(VI_PIPE_ID, &pipe)) ||
        (result = p_GK_API_VI_StartPipe(VI_PIPE_ID))) {
        step("vi pipe", result);
        return 1;
    }

    VI_CHN_ATTR_S channel;
    memset(&channel, 0, sizeof(channel));
    channel.stSize.u32Width = SENSOR_WIDTH;
    channel.stSize.u32Height = SENSOR_HEIGHT;
    channel.enPixelFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420;
    channel.enDynamicRange = DYNAMIC_RANGE_SDR8;
    channel.enVideoFormat = VIDEO_FORMAT_LINEAR;
    channel.enCompressMode = COMPRESS_MODE_NONE;
    channel.stFrameRate.s32SrcFrameRate = -1;
    channel.stFrameRate.s32DstFrameRate = -1;
    if ((result = p_GK_API_VI_SetChnAttr(VI_PIPE_ID, VI_CHANNEL, &channel)) ||
        (result = p_GK_API_VI_EnableChn(VI_PIPE_ID, VI_CHANNEL))) {
        step("vi channel", result);
        return 1;
    }
    step("vi", 0);
    return 0;
}

/* Reads the line an earlier run printed after "state:". */
static int read_initial_exposure(ISP_INIT_ATTR_S *initial)
{
    char text[160];
    int fd = (int)syscall(__NR_open, exposure_file, O_RDONLY, 0);
    if (fd < 0)
        return 1;
    long length = syscall(__NR_read, fd, text, sizeof(text) - 1);
    syscall(__NR_close, fd);
    if (length <= 0)
        return 1;
    text[length] = 0;
    GK_U32 values[7];
    const char *cursor = text;
    for (int i = 0; i < 7; ++i) {
        while (*cursor == ' ')
            ++cursor;
        if (*cursor < '0' || *cursor > '9')
            return 1;
        GK_U32 value = 0;
        while (*cursor >= '0' && *cursor <= '9')
            value = value * 10 + (GK_U32)(*cursor++ - '0');
        values[i] = value;
    }
    memset(initial, 0, sizeof(*initial));
    initial->u32ExpTime = values[0];
    initial->u32AGain = values[1];
    initial->u32DGain = values[2];
    initial->u32ISPDGain = values[3];
    initial->u32Exposure = values[4];
    initial->u32LinesPer500ms = values[5];
    initial->u32InitIso = values[6];
    return 0;
}

static int configure_isp(void)
{
    long result;
    ISP_SNS_COMMBUS_U bus = {.s8I2cDev = SENSOR_I2C_BUS};
    if ((result = sensor->pfnSetBusInfo(VI_PIPE_ID, bus)) ||
        (result = sensor->pfnRegisterCallback(VI_PIPE_ID, &ae_library, &awb_library)) ||
        (result = p_GK_API_AE_Register(VI_PIPE_ID, &ae_library)) ||
        (result = p_GK_API_AWB_Register(VI_PIPE_ID, &awb_library))) {
        step("sensor and 3A libraries", result);
        return 1;
    }
    if (exposure_file) {
        ISP_INIT_ATTR_S initial;
        if (!sensor->pfnSetInit)
            step("initial exposure: the sensor library has no SetInit", -1);
        else if (read_initial_exposure(&initial))
            step("initial exposure: unreadable file", -1);
        else
            step("initial exposure", sensor->pfnSetInit(VI_PIPE_ID, &initial));
    }
    if ((result = p_GK_API_ISP_MemInit(VI_PIPE_ID))) {
        step("isp memory", result);
        return 1;
    }
    ISP_PUB_ATTR_S public;
    memset(&public, 0, sizeof(public));
    public.stWndRect.u32Width = SENSOR_WIDTH;
    public.stWndRect.u32Height = SENSOR_HEIGHT;
    public.stSnsSize.u32Width = SENSOR_WIDTH;
    public.stSnsSize.u32Height = SENSOR_HEIGHT;
    public.f32FrameRate = (GK_FLOAT)fps;
    public.enBayer = BAYER_RGGB;
    public.enWDRMode = WDR_MODE_NONE;
    public.u8SnsMode = 0;
    if ((result = p_GK_API_ISP_SetPubAttr(VI_PIPE_ID, &public)) || (result = p_GK_API_ISP_Init(VI_PIPE_ID))) {
        step("isp", result);
        return 1;
    }
    step("isp", 0);
    return 0;
}

static int configure_vpss(void)
{
    VPSS_GRP_ATTR_S group;
    memset(&group, 0, sizeof(group));
    group.u32MaxW = SENSOR_WIDTH;
    group.u32MaxH = SENSOR_HEIGHT;
    group.enPixelFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420;
    group.enDynamicRange = DYNAMIC_RANGE_SDR8;
    group.stFrameRate.s32SrcFrameRate = -1;
    group.stFrameRate.s32DstFrameRate = -1;
    group.bNrEn = GK_TRUE;
    group.stNrAttr.enNrType = VPSS_NR_TYPE_VIDEO;
    group.stNrAttr.enCompressMode = COMPRESS_MODE_NONE;
    group.stNrAttr.enNrMotionMode = NR_MOTION_MODE_NORMAL;
    long result;
    if ((result = p_GK_API_VPSS_CreateGrp(VPSS_GROUP, &group)) || (result = p_GK_API_VPSS_StartGrp(VPSS_GROUP))) {
        step("vpss group", result);
        return 1;
    }
    MPP_CHN_S source = {.enModId = MOD_ID_VI, .s32DevId = VI_PIPE_ID, .s32ChnId = VI_CHANNEL};
    MPP_CHN_S destination = {.enModId = MOD_ID_VPSS, .s32DevId = VPSS_GROUP, .s32ChnId = 0};
    if ((result = p_GK_API_SYS_Bind(&source, &destination))) {
        step("vi to vpss", result);
        return 1;
    }

    VPSS_CHN_ATTR_S channel;
    memset(&channel, 0, sizeof(channel));
    channel.enChnMode = VPSS_CHN_MODE_USER;
    channel.u32Width = (GK_U32)width;
    channel.u32Height = (GK_U32)height;
    channel.enVideoFormat = VIDEO_FORMAT_LINEAR;
    channel.enPixelFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420;
    channel.enDynamicRange = DYNAMIC_RANGE_SDR8;
    channel.enCompressMode = COMPRESS_MODE_NONE;
    channel.stFrameRate.s32SrcFrameRate = -1;
    channel.stFrameRate.s32DstFrameRate = -1;
    if ((result = p_GK_API_VPSS_SetChnAttr(VPSS_GROUP, VPSS_CHANNEL, &channel)) ||
        (result = p_GK_API_VPSS_EnableChn(VPSS_GROUP, VPSS_CHANNEL))) {
        step("vpss channel", result);
        return 1;
    }
    step("vpss", 0);
    return 0;
}

static int configure_venc(void)
{
    VENC_CHN_ATTR_S attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.stVencAttr.enType = PT_JPEG;
    attributes.stVencAttr.u32MaxPicWidth = (GK_U32)width;
    attributes.stVencAttr.u32MaxPicHeight = (GK_U32)height;
    attributes.stVencAttr.u32BufSize = align_up((GK_U32)(width * height * 3 / 4), 64);
    attributes.stVencAttr.bByFrame = GK_TRUE;
    attributes.stVencAttr.u32PicWidth = (GK_U32)width;
    attributes.stVencAttr.u32PicHeight = (GK_U32)height;
    attributes.stVencAttr.stAttrJpege.enReceiveMode = VENC_PIC_RECEIVE_SINGLE;
    attributes.stGopAttr.enGopMode = VENC_GOPMODE_NORMALP;
    long result;
    if ((result = p_GK_API_VENC_CreateChn(VENC_CHANNEL, &attributes))) {
        step("jpeg channel", result);
        return 1;
    }
    VENC_JPEG_PARAM_S jpeg;
    if (!p_GK_API_VENC_GetJpegParam(VENC_CHANNEL, &jpeg)) {
        jpeg.u32Qfactor = (GK_U32)quality;
        p_GK_API_VENC_SetJpegParam(VENC_CHANNEL, &jpeg);
    }
    MPP_CHN_S source = {.enModId = MOD_ID_VPSS, .s32DevId = VPSS_GROUP, .s32ChnId = VPSS_CHANNEL};
    MPP_CHN_S destination = {.enModId = MOD_ID_VENC, .s32DevId = 0, .s32ChnId = VENC_CHANNEL};
    if ((result = p_GK_API_SYS_Bind(&source, &destination))) {
        step("vpss to jpeg", result);
        return 1;
    }
    step("jpeg", 0);
    return 0;
}

static void *isp_thread(void *unused)
{
    (void)unused;
    long result = p_GK_API_ISP_Run(VI_PIPE_ID);
    if (result)
        step("isp run", result);
    return NULL;
}

static void print_exposure(const char *label)
{
    if (p_GK_API_ISP_QueryExposureInfo(VI_PIPE_ID, &exposure))
        return;
    struct line line = {.length = 0};
    add_text(&line, "  ");
    add_text(&line, label);
    add_field(&line, ": luma ", exposure.u8AveLum);
    add_text(&line, ", histogram error ");
    add_signed(&line, exposure.s16HistError);
    add_field(&line, ", exposure ", exposure.u32Exposure);
    add_field(&line, " (time ", exposure.u32ExpTime);
    add_field(&line, ", again ", exposure.u32AGain);
    add_field(&line, ", dgain ", exposure.u32DGain);
    add_field(&line, ", ispdgain ", exposure.u32ISPDGain);
    add_field(&line, "), iso ", exposure.u32ISO);
    add_field(&line, ", fps ", exposure.u32Fps);
    add_field(&line, ", stable after ", exposure.u32FirstStableTime);
    finish(&line, 1);
}

static int write_picture(int index, VENC_STREAM_S *stream)
{
    struct line path = {.length = 0};
    add_text(&path, prefix);
    add_text(&path, "-");
    add_number(&path, (unsigned long)index, 10, 0);
    add_text(&path, ".jpg");
    path.text[path.length] = 0;
    int fd = (int)syscall(__NR_open, path.text, O_WRONLY_CREAT_TRUNC, 0600);
    if (fd < 0)
        return 1;
    unsigned long bytes = 0;
    for (GK_U32 i = 0; i < stream->u32PackCount; ++i) {
        VENC_PACK_S *pack = &stream->pstPack[i];
        GK_U32 length = pack->u32Len - pack->u32Offset;
        if (syscall(__NR_write, fd, pack->pu8Addr + pack->u32Offset, length) != (long)length) {
            syscall(__NR_close, fd);
            return 1;
        }
        bytes += length;
    }
    syscall(__NR_close, fd);
    struct line line = {.length = 0};
    add_time(&line);
    add_field(&line, "picture ", (unsigned long)index);
    add_field(&line, ": ", bytes);
    add_text(&line, " bytes in ");
    add_text(&line, path.text);
    finish(&line, 1);
    return 0;
}

static int capture(void)
{
    VENC_RECV_PIC_PARAM_S receive = {.s32RecvPicNum = pictures};
    long result = p_GK_API_VENC_StartRecvFrame(VENC_CHANNEL, &receive);
    if (result) {
        step("start receiving", result);
        return 1;
    }
    struct pollfd32 wait = {.fd = p_GK_API_VENC_GetFd(VENC_CHANNEL), .events = POLLIN};
    static VENC_PACK_S packs[MAX_PACKS];
    for (int index = 1; index <= pictures; ++index) {
        wait.revents = 0;
        if (syscall(__NR_poll, &wait, 1, PICTURE_TIMEOUT_MS) <= 0) {
            step("picture timeout", index);
            return 1;
        }
        VENC_CHN_STATUS_S status;
        if ((result = p_GK_API_VENC_QueryStatus(VENC_CHANNEL, &status)) || !status.u32CurPacks ||
            status.u32CurPacks > MAX_PACKS) {
            step("picture status", result ? result : (long)status.u32CurPacks);
            return 1;
        }
        VENC_STREAM_S stream;
        memset(&stream, 0, sizeof(stream));
        stream.pstPack = packs;
        stream.u32PackCount = status.u32CurPacks;
        if ((result = p_GK_API_VENC_GetStream(VENC_CHANNEL, &stream, PICTURE_TIMEOUT_MS))) {
            step("get picture", result);
            return 1;
        }
        int failed = write_picture(index, &stream);
        p_GK_API_VENC_ReleaseStream(VENC_CHANNEL, &stream);
        print_exposure("ae");
        if (failed) {
            step("write picture", -1);
            return 1;
        }
    }
    /* The line for -e on the next run. */
    struct line line = {.length = 0};
    add_field(&line, "state: ", exposure.u32ExpTime);
    add_field(&line, " ", exposure.u32AGain);
    add_field(&line, " ", exposure.u32DGain);
    add_field(&line, " ", exposure.u32ISPDGain);
    add_field(&line, " ", exposure.u32Exposure);
    add_field(&line, " ", exposure.u32LinesPer500ms);
    add_field(&line, " ", exposure.u32ISO);
    finish(&line, 1);
    return 0;
}

/* Undoes as much as was set up, so that Majestic can start afterwards; errors are only reported. */
static void tear_down(int isp_running, unsigned long isp)
{
    MPP_CHN_S vi = {.enModId = MOD_ID_VI, .s32DevId = VI_PIPE_ID, .s32ChnId = VI_CHANNEL};
    MPP_CHN_S vpss_in = {.enModId = MOD_ID_VPSS, .s32DevId = VPSS_GROUP, .s32ChnId = 0};
    MPP_CHN_S vpss_out = {.enModId = MOD_ID_VPSS, .s32DevId = VPSS_GROUP, .s32ChnId = VPSS_CHANNEL};
    MPP_CHN_S venc = {.enModId = MOD_ID_VENC, .s32DevId = 0, .s32ChnId = VENC_CHANNEL};
    p_GK_API_VENC_StopRecvFrame(VENC_CHANNEL);
    p_GK_API_SYS_UnBind(&vpss_out, &venc);
    p_GK_API_VENC_DestroyChn(VENC_CHANNEL);
    p_GK_API_SYS_UnBind(&vi, &vpss_in);
    p_GK_API_VPSS_DisableChn(VPSS_GROUP, VPSS_CHANNEL);
    p_GK_API_VPSS_StopGrp(VPSS_GROUP);
    p_GK_API_VPSS_DestroyGrp(VPSS_GROUP);
    p_GK_API_ISP_Exit(VI_PIPE_ID);
    if (isp_running)
        pthread_join(isp, NULL);
    p_GK_API_AWB_UnRegister(VI_PIPE_ID, &awb_library);
    p_GK_API_AE_UnRegister(VI_PIPE_ID, &ae_library);
    if (sensor)
        sensor->pfnUnRegisterCallback(VI_PIPE_ID, &ae_library, &awb_library);
    p_GK_API_VI_DisableChn(VI_PIPE_ID, VI_CHANNEL);
    p_GK_API_VI_StopPipe(VI_PIPE_ID);
    p_GK_API_VI_DestroyPipe(VI_PIPE_ID);
    p_GK_API_VI_DisableDev(VI_DEVICE);
    p_GK_API_SYS_Exit();
    p_GK_API_VB_Exit();
    step("torn down", 0);
}

static int parse_number(const char *text, int minimum, int maximum, int *value)
{
    long result = 0;
    if (!text || !*text)
        return 1;
    for (; *text; ++text) {
        if (*text < '0' || *text > '9')
            return 1;
        result = result * 10 + (*text - '0');
        if (result > maximum)
            return 1;
    }
    if (result < minimum)
        return 1;
    *value = (int)result;
    return 0;
}

static int parse_arguments(int count, char **arguments)
{
    for (int i = 1; i < count; i += 2) {
        const char *flag = arguments[i];
        const char *value = i + 1 < count ? arguments[i + 1] : NULL;
        if (!value || flag[0] != '-' || !flag[1] || flag[2])
            return 1;
        switch (flag[1]) {
        case 'n': if (parse_number(value, 1, MAX_PICTURES, &pictures)) return 1; break;
        case 'w': if (parse_number(value, 64, SENSOR_WIDTH, &width) || width % 2) return 1; break;
        case 'h': if (parse_number(value, 64, SENSOR_HEIGHT, &height) || height % 2) return 1; break;
        case 'q': if (parse_number(value, 1, 99, &quality)) return 1; break;
        case 'f': if (parse_number(value, 5, 30, &fps)) return 1; break;
        case 'o': prefix = value; break;
        case 'e': exposure_file = value; break;
        default: return 1;
        }
    }
    return 0;
}

static int main(int count, char **arguments, char **environment);

/* musl's crt1 is not part of the build: start the same way, through __libc_start_main, so that libc (and with it
 * dlopen and threads) is initialised before main runs. */
extern int __libc_start_main(int (*main)(int, char **, char **), int count, char **arguments, void (*)(void),
                             void (*)(void), void (*)(void));

__attribute__((used)) static void start_c(long *stack)
{
    __libc_start_main(main, (int)stack[0], (char **)(stack + 1), 0, 0, 0);
}

__asm__(".text\n.global _start\n.type _start,%function\n_start:\n"
        "\tmov fp, #0\n\tmov lr, #0\n\tmov r0, sp\n\tbic sp, sp, #15\n\tbl start_c\n");

static int main(int count, char **arguments, char **environment)
{
    (void)environment;
    started_ms = boot_ms();
    if (parse_arguments(count, arguments)) {
        say(2, "usage: first-snap [-n pictures] [-w width] [-h height] [-q quality] [-f fps] [-o prefix] ",
            "[-e exposure-file]");
        return 2;
    }
    step("start", 0);
    if (load_vendor())
        return 1;
    if (!(sensor = (ISP_SNS_OBJ_S *)dlsym(last_library, SENSOR_OBJECT))) {
        say(2, "missing ", SENSOR_OBJECT);
        return 1;
    }
    step("libraries", 0);

    unsigned long isp = 0;
    int isp_running = 0;
    int failed = configure_buffers();
    if (!failed)
        failed = configure_mipi() || configure_vi() || configure_isp() || configure_vpss();
    if (!failed) {
        isp_running = pthread_create(&isp, NULL, isp_thread, NULL) == 0;
        step("isp thread", !isp_running);
        failed = !isp_running || configure_venc() || capture();
    }
    tear_down(isp_running, isp);
    return failed;
}
