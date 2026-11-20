#include <asm/unistd.h>
#include <stddef.h>

#include "gk_api_sys.h"
#include "gk_api_vb.h"
#include "gk_api_vo.h"
#include "gk_api_vpss.h"

#define WIDTH 480
#define HEIGHT 272
#define LCD_VPSS_CHANNEL 2
#define LCD_FRAMES 200
#define LUMA_BYTES (WIDTH * HEIGHT)
#define LCD_FRAME_BYTES (LUMA_BYTES * 3 / 2)

static long syscall3(long number, long first, long second, long third)
{
    register long r0 __asm__("r0") = first;
    register long r1 __asm__("r1") = second;
    register long r2 __asm__("r2") = third;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory", "cc");
    return r0;
}

/* The vendor library passes a 32-bit offset even under musl. */
extern long syscall(long number, ...);

void *mmap(void *address, size_t length, int protection, int flags, int fd,
           unsigned long offset)
{
    return (void *)syscall(__NR_mmap2, address, length, protection, flags, fd,
                           offset >> 12);
}

extern void *memcpy(void *, const void *, size_t);

static int report(const char *name, size_t length, unsigned long result)
{
    char status[] = ": 0x00000000\n";
    static const char digits[] = "0123456789abcdef";
    for (int i = 0; i < 8; ++i)
        status[4 + i] = digits[(result >> ((7 - i) * 4)) & 15];
    syscall3(__NR_write, 1, (long)name, length);
    syscall3(__NR_write, 1, (long)status, sizeof(status) - 1);
    return result != 0;
}

#define REPORT(name, result) report(name, sizeof(name) - 1, (result))

static int copy_plane(void *output, GK_U64 physical, GK_U32 stride, GK_U32 rows)
{
    if (!physical || stride < WIDTH || stride > 2048)
        return 1;
    GK_U32 length = stride * rows;
    const char *input = GK_API_SYS_Mmap(physical, length);
    if (!input || input == (void *)-1)
        return 1;
    for (GK_U32 row = 0; row < rows; ++row)
        memcpy((char *)output + row * WIDTH, input + row * stride, WIDTH);
    return GK_API_SYS_Munmap((void *)input, length) != 0;
}

static int queue_frame(VB_POOL pool, VIDEO_FRAME_INFO_S *input)
{
    VB_BLK block = GK_API_VB_GetBlock(pool, LCD_FRAME_BYTES, NULL);
    if (block == VB_INVALID_HANDLE) {
        REPORT("Get private buffer", block);
        return 1;
    }
    GK_U64 physical = GK_API_VB_Handle2PhysAddr(block);
    void *mapping = physical ? GK_API_SYS_Mmap(physical, LCD_FRAME_BYTES) : NULL;
    int failed = 1;
    if (!mapping || mapping == (void *)-1) {
        REPORT("Map private buffer", -1);
    } else {
        const VIDEO_FRAME_S *source = &input->stVFrame;
        failed = copy_plane(mapping, source->u64PhyAddr[0], source->u32Stride[0], HEIGHT) ||
                 copy_plane((char *)mapping + LUMA_BYTES, source->u64PhyAddr[1], source->u32Stride[1], HEIGHT / 2);
        if (failed)
            REPORT("Copy VPSS frame", -1);
        else {
            static VIDEO_FRAME_INFO_S output = {
                .stVFrame = {
                    .u32Width = WIDTH,
                    .u32Height = HEIGHT,
                    .enField = VIDEO_FIELD_FRAME,
                    .enPixelFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420,
                    .enVideoFormat = VIDEO_FORMAT_LINEAR,
                    .enCompressMode = COMPRESS_MODE_NONE,
                    .enDynamicRange = DYNAMIC_RANGE_SDR8,
                    .enColorGamut = COLOR_GAMUT_BT601,
                    .u32Stride = {WIDTH, WIDTH, WIDTH},
                },
                .enModId = MOD_ID_USER,
            };
            output.u32PoolId = pool;
            output.stVFrame.u64PTS = source->u64PTS;
            output.stVFrame.u32TimeRef = source->u32TimeRef;
            output.stVFrame.u64PhyAddr[0] = physical;
            output.stVFrame.u64PhyAddr[1] = physical + LUMA_BYTES;
            output.stVFrame.u64PhyAddr[2] = physical + LUMA_BYTES;
            output.stVFrame.u64VirAddr[0] = (unsigned long)mapping;
            output.stVFrame.u64VirAddr[1] = (unsigned long)mapping + LUMA_BYTES;
            output.stVFrame.u64VirAddr[2] = (unsigned long)mapping + LUMA_BYTES;
            GK_S32 result = GK_API_VO_SendFrame(0, 0, &output, 350);
            if (result)
                failed = REPORT("Send camera frame", result);
        }
        GK_S32 result = GK_API_SYS_Munmap(mapping, LCD_FRAME_BYTES);
        if (result)
            failed |= REPORT("Unmap private buffer", result);
    }
    GK_S32 result = GK_API_VB_ReleaseBlock(block);
    if (result)
        failed |= REPORT("Release private buffer", result);
    return failed;
}

static int show_live(void)
{
    static VB_POOL_CONFIG_S pool_config = {
        .u64BlkSize = LCD_FRAME_BYTES,
        .u32BlkCnt = 8,
        .enRemapMode = VB_REMAP_MODE_NONE,
    };
    static const VPSS_CHN_ATTR_S capture = {
        .enChnMode = VPSS_CHN_MODE_USER,
        .u32Width = WIDTH,
        .u32Height = HEIGHT,
        .enVideoFormat = VIDEO_FORMAT_LINEAR,
        .enPixelFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420,
        .enDynamicRange = DYNAMIC_RANGE_SDR8,
        .enCompressMode = COMPRESS_MODE_NONE,
        .stFrameRate = {.s32SrcFrameRate = 25, .s32DstFrameRate = 5},
        .u32Depth = 1,
    };
    static VO_PUB_ATTR_S attributes = {
        .u32BgColor = 0x00ff00,
        .enIntfType = VO_INTF_LCD_8BIT,
        .enIntfSync = VO_OUTPUT_USER,
        .stSyncInfo = {
            .bSynm = GK_TRUE, .bIop = GK_TRUE, .u8Intfb = 1,
            .u16Vact = HEIGHT, .u16Vbb = 15, .u16Vfb = 9,
            .u16Hact = WIDTH, .u16Hbb = 65, .u16Hfb = 7, .u16Hmid = 1,
            .u16Bvact = HEIGHT, .u16Bvbb = 14, .u16Bvfb = 9,
            .u16Hpw = 1, .u16Vpw = 1,
        },
    };
    static VO_USER_INTFSYNC_INFO_S clock = {
        .stUserIntfSyncAttr = {
            .enClkSource = VO_CLK_SOURCE_LCDMCLK,
            .u32LcdMClkDiv = 0x001ef73d,
        },
        .u32PreDiv = 1,
        .u32DevDiv = 3,
    };
    static const VO_VIDEO_LAYER_ATTR_S layer = {
        .stDispRect = {.u32Width = WIDTH, .u32Height = HEIGHT},
        .stImageSize = {.u32Width = WIDTH, .u32Height = HEIGHT},
        .u32DispFrmRt = 30,
        .enPixFormat = PIXEL_FORMAT_YVU_SEMIPLANAR_420,
        .enDstDynamicRange = DYNAMIC_RANGE_SDR8,
    };
    static const VO_CSC_S csc = {
        .enCscMatrix = VO_CSC_MATRIX_BT601_TO_RGB_PC,
        .u32Luma = 50, .u32Contrast = 50, .u32Hue = 50, .u32Satuature = 50,
    };
    static const VO_CHN_ATTR_S channel = {
        .stRect = {.u32Width = WIDTH, .u32Height = HEIGHT},
    };
    static VPSS_CHN_ATTR_S previous;
    static VIDEO_FRAME_INFO_S frame;
    long started[2], now[2];
    int failed = 1;

    if (REPORT("Read previous VPSS attributes", GK_API_VPSS_GetChnAttr(0, LCD_VPSS_CHANNEL, &previous)))
        return failed;
    REPORT("Previous VPSS width (hex)", previous.u32Width);
    REPORT("Previous VPSS height (hex)", previous.u32Height);
    VB_POOL pool = GK_API_VB_CreatePool(&pool_config);
    if (REPORT("Create private pool", pool == VB_INVALID_POOLID ? pool : 0))
        return failed;
    if (REPORT("Set LCD VPSS attributes", GK_API_VPSS_SetChnAttr(0, LCD_VPSS_CHANNEL, &capture)))
        goto destroy_pool;
    if (REPORT("Enable LCD VPSS channel", GK_API_VPSS_EnableChn(0, LCD_VPSS_CHANNEL)))
        goto restore_capture;

    if (REPORT("Set public attributes", GK_API_VO_SetPubAttr(0, &attributes)) ||
        REPORT("Set frame rate", GK_API_VO_SetDevFrameRate(0, 30)) ||
        REPORT("Set clock", GK_API_VO_SetUserIntfSyncInfo(0, &clock)) ||
        REPORT("Enable device", GK_API_VO_Enable(0)))
        goto disable_capture;
    if (REPORT("Set layer attributes", GK_API_VO_SetVideoLayerAttr(0, &layer)) ||
        REPORT("Enable layer", GK_API_VO_EnableVideoLayer(0)))
        goto disable_device;
    if (REPORT("Set BT.601 to RGB", GK_API_VO_SetVideoLayerCSC(0, &csc)))
        goto disable_layer;
    if (REPORT("Set channel attributes", GK_API_VO_SetChnAttr(0, 0, &channel)) ||
        REPORT("Enable channel", GK_API_VO_EnableChn(0, 0)))
        goto disable_layer;
    if (REPORT("Show channel", GK_API_VO_ShowChn(0, 0)) ||
        REPORT("Start monotonic timer", syscall3(__NR_clock_gettime, 1, (long)started, 0)))
        goto disable_channel;

    GK_U32 submitted = 0;
    GK_U64 last_pts = 0;
    while (submitted < LCD_FRAMES) {
        if (syscall3(__NR_clock_gettime, 1, (long)now, 0) != 0) {
            REPORT("Read monotonic timer", -1);
            goto disable_channel;
        }
        if (now[0] - started[0] >= 36)
            break;
        GK_S32 result = GK_API_VPSS_GetChnFrame(0, LCD_VPSS_CHANNEL, &frame, 450);
        if (result) {
            REPORT("Get VPSS frame", result);
            goto disable_channel;
        }
        if (frame.stVFrame.u32Width != WIDTH || frame.stVFrame.u32Height != HEIGHT ||
            frame.stVFrame.enPixelFormat != PIXEL_FORMAT_YVU_SEMIPLANAR_420 ||
            frame.stVFrame.enCompressMode != COMPRESS_MODE_NONE ||
            frame.stVFrame.u64PTS <= last_pts) {
            REPORT("Validate VPSS frame", -1);
            result = -1;
        } else {
            last_pts = frame.stVFrame.u64PTS;
            result = queue_frame(pool, &frame);
        }
        GK_S32 released = GK_API_VPSS_ReleaseChnFrame(0, LCD_VPSS_CHANNEL, &frame);
        if (released)
            REPORT("Release VPSS frame", released);
        if (result || released)
            goto disable_channel;
        if (++submitted == 3)
            REPORT("Live frames ready", 0);
    }
    REPORT("Live frames submitted (hex)", submitted);
    failed = submitted < 150;

 disable_channel:
    failed |= REPORT("Disable channel", GK_API_VO_DisableChn(0, 0));
 disable_layer:
    failed |= REPORT("Disable layer", GK_API_VO_DisableVideoLayer(0));
 disable_device:
    failed |= REPORT("Disable device", GK_API_VO_Disable(0));
 disable_capture:
    failed |= REPORT("Disable LCD VPSS channel", GK_API_VPSS_DisableChn(0, LCD_VPSS_CHANNEL));
 restore_capture:
    if (previous.u32Width && previous.u32Height)
        failed |= REPORT("Restore LCD VPSS attributes", GK_API_VPSS_SetChnAttr(0, LCD_VPSS_CHANNEL, &previous));
    else
        REPORT("Initially unconfigured VPSS channel left disabled", 0);
 destroy_pool:
    failed |= REPORT("Destroy private pool", GK_API_VB_DestroyPool(pool));
    return failed;
}

void _start(void)
{
    syscall3(__NR_exit, show_live(), 0, 0);
    __builtin_unreachable();
}
