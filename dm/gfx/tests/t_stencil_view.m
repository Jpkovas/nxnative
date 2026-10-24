// Depth-stencil sampling must not recreate the attachment to expose its stencil plane.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
int main(void) { @autoreleasepool {
    mtl_init();
    int formats[] = {NVN_FORMAT_DEPTH24_STENCIL8, NVN_FORMAT_DEPTH32F_STENCIL8};
    for (int i = 0; i < 2; i++) {
        tex_t t = {.magic=MAGIC('T','E','X',0), .serial=99201u+i};
        t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=formats[i], .width=4, .height=4, .depth=1, .levels=1, .samples=1};
        MTLTextureDescriptor *td = tex_desc(&t, 0);
        CHECK(td.usage & MTLTextureUsagePixelFormatView, "depth-stencil creation permits its stencil view");
        if (!(td.usage & MTLTextureUsagePixelFormatView)) continue;
        id<MTLTexture> base = [g_dev newTextureWithDescriptor:td];
        CHECK(base != nil, "depth-stencil texture allocated");
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = rp.stencilAttachment.texture = base;
        rp.depthAttachment.loadAction = rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = rp.stencilAttachment.storeAction = MTLStoreActionStore;
        rp.depthAttachment.clearDepth = 0.25; rp.stencilAttachment.clearStencil = 0x5a;
        id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "literal depth-stencil clear completed");
        serial_put(t.serial, base);
        view_t v = {.set_dsmode=1, .dsmode=NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL};
        int tid = 700 + i; mtl_reg_tex(tid, &t, &v);
        pthread_mutex_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); pthread_mutex_unlock(&g_rmu);
        CHECK(view && view.pixelFormat == MTLPixelFormatX32_Stencil8, "production lookup exposes the stencil plane");
        CHECK(tex_get(t.serial) == base && view.parentTexture == base, "attachment storage is retained");
        NSError *error = nil;
        id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void read_stencil(texture2d<uint,access::read> s [[texture(0)]], depth2d<float,access::read> d [[texture(1)]], device uint2 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { o[p.y*4+p.x]=uint2(s.read(p).r, as_type<uint>(d.read(p))); }\n" options:nil error:&error];
        id<MTLComputePipelineState> pipeline = [g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_stencil"] error:&error];
        CHECK(pipeline != nil, "synthetic stencil reader compiles");
        id<MTLBuffer> output = [g_dev newBufferWithLength:16*8 options:MTLResourceStorageModeShared];
        cb = [queue commandBuffer]; id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setTexture:view atIndex:0]; [encoder setTexture:base atIndex:1]; [encoder setBuffer:output offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(4,4,1) threadsPerThreadgroup:MTLSizeMake(4,4,1)];
        [encoder endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "stencil/depth read completed");
        uint32_t *p = output.contents; int ok = 1;
        for (int j = 0; j < 16; j++) ok &= p[2*j] == 0x5a && p[2*j+1] == 0x3e800000;
        CHECK(ok, "every pixel retains both literal stencil and depth");
    }
    printf("stencil views: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
