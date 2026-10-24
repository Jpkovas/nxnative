// Many resolution descriptors share physical memory; the active image stays exact.
#include "../nvn/nvn_mtl.m"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c,label) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
static tex_t make_tex(pool_t *pool, uint64_t serial, unsigned w, unsigned h, int format, int64_t off) {
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=serial,.pool=pool,.off=off};
    t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=format,.width=w,.height=h,.depth=1,.levels=1,.samples=1,.flags=NVN_TEXTURE_FLAGS_COMPRESSIBLE|NVN_TEXTURE_FLAGS_IMAGE};
    nvn_tex_layout(&t.d,&t.L);return t;
}
static void *nvn_proc(const char *name) {
    typedef struct { const char *name; void *fn; } entry;
    unsigned long bytes=0;
    const entry *entries=(const void *)getsectiondata(&_mh_execute_header,"__DATA","swnvn",&bytes);
    for(unsigned long i=0;i<bytes/sizeof *entries;i++)if(!strcmp(entries[i].name,name))return entries[i].fn;
    fprintf(stderr,"Missing NVN procedure: %s\n",name);exit(1);
}
// Read indirectly through an argument buffer on Metal4. Only the parent heap is
// resident: the texture is intentionally absent from the residency set.
static void indirect_read(id<MTLTexture> t, unsigned seed) {
    static id<MTLFunction> function;
    static id<MTLComputePipelineState> pipeline;
    if (!pipeline) {
        NSError *error=nil;
        id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { texture2d<uint,access::read> image [[id(0)]]; }; kernel void read_image(constant Args &a [[buffer(0)]],device uint4 *out [[buffer(1)]],uint2 p [[thread_position_in_grid]]) { if(p.x<a.image.get_width()&&p.y<a.image.get_height())out[p.y*a.image.get_width()+p.x]=a.image.read(p); }" options:nil error:&error];
        function=[library newFunctionWithName:@"read_image"];
        pipeline=[g_dev newComputePipelineStateWithFunction:function error:&error];
        CHECK(pipeline!=nil,"indirect Metal4 reader compiles");
    }
    id<MTLArgumentEncoder> arguments=[function newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> table=[g_dev newBufferWithLength:arguments.encodedLength options:MTLResourceStorageModeShared];
    [arguments setArgumentBuffer:table offset:0];[arguments setTexture:t atIndex:0];
    id<MTLBuffer> output=[g_dev newBufferWithLength:t.width*t.height*16 options:MTLResourceStorageModeShared];
    memset(output.contents,0xee,output.length);res_add(table);res_add(output);res_commit();
    CHECK(![g_res_objects containsObject:t],"indirect image is covered by its resident heap");
    mtl_sub_begin();id<MTL4ComputeCommandEncoder> e=enc_c_begin(nil);enc_c_pso(e,pipeline);
    enc_c_args(e,table.gpuAddress,0);enc_c_args(e,output.gpuAddress,1);
    enc_c_dispatch(e,MTLSizeMake((t.width+7)/8,(t.height+7)/8,1),MTLSizeMake(8,8,1));enc_c_end(e);
    mtl_sub_commit();mtl_drain();CHECK(!mtl_last_commit_error(),"indirect heap texture read completes");
    uint32_t *p=output.contents;int valid=1;
    for(NSUInteger y=0;y<t.height;y++)for(NSUInteger x=0;x<t.width;x++)for(unsigned c=0;c<4;c++)
        valid&=p[(y*t.width+x)*4+c]==(uint8_t)(seed+(x*4+c)*7+y*13);
    CHECK(valid,"all indirect shader reads match the literal uploaded pixels");
    res_remove(table);res_remove(output);res_commit();
}
static void literal_roundtrip(id<MTLTexture> t, unsigned seed) {
    NSUInteger row=((t.width*4+255)/256)*256, length=row*t.height;
    id<MTLBuffer> input=[g_dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[g_dev newBufferWithLength:length options:MTLResourceStorageModeShared];
    for(NSUInteger y=0;y<t.height;y++)for(NSUInteger x=0;x<t.width*4;x++)((uint8_t *)input.contents)[y*row+x]=(uint8_t)(seed+x*7+y*13);
    res_add(input);res_add(output);res_commit();
    mtl_sub_begin();
    enc_b_copy_buffer_texture(blit(),input,0,row,length,MTLSizeMake(t.width,t.height,1),t,0,0,MTLOriginMake(0,0,0));
    enc_b_copy_texture_buffer(blit(),t,0,0,MTLOriginMake(0,0,0),MTLSizeMake(t.width,t.height,1),output,0,row,length);
    mtl_sub_commit();mtl_drain();
    CHECK(!mtl_last_commit_error(),"Metal4 alias upload/readback completes");
    int valid=1;for(NSUInteger y=0;y<t.height;y++)valid&=!memcmp((uint8_t *)input.contents+y*row,(uint8_t *)output.contents+y*row,t.width*4);
    CHECK(valid,"every literal active pixel survives the shared allocation");
    indirect_read(t,seed);
    res_remove(input);res_remove(output);res_commit();
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_ALIAS_HEAPS","1",1);mtl_init();
    pool_t pool={0},other_pool={0};tex_t images[128];
    uint64_t before=g_dev.currentAllocatedSize;
    id<MTLHeap> first=nil;
    for(unsigned i=0;i<128;i++) {
        images[i]=make_tex(&pool,80000+i,1024+i*2,576+i,NVN_FORMAT_RGBA8UI,0);
        mtl_tex_init(&images[i]);id<MTLTexture> image=tex_mtl(&images[i]);
        CHECK(image.heap!=nil,"compressible image uses placement storage");
        if(!first)first=image.heap;
        CHECK(image.heap==first,"resolution variants share one physical allocation");
        CHECK(image.usage&MTLTextureUsagePixelFormatView,"views do not require a standalone upgrade");
    }
    uint64_t delta=g_dev.currentAllocatedSize-before;
    printf("128 live resolution descriptors: %llu MiB device allocation delta\n",(unsigned long long)(delta>>20));
    CHECK(delta<(32u<<20),"physical allocation is bounded while every descriptor remains live");
    CHECK([g_res_objects containsObject:first],"the heap is resident for Metal4");
    for(unsigned i=0;i<128;i+=7)literal_roundtrip(tex_mtl(&images[i]),i*31);
    // Revisit old descriptors after many other dimensions wrote the aliased heap.
    for(int i=126;i>=0;i-=13)literal_roundtrip(tex_mtl(&images[i]),i*17);
    tex_t different=make_tex(&pool,81000,1024,576,NVN_FORMAT_RGBA8UI,0x800000);
    tex_t independent=make_tex(&other_pool,81001,1024,576,NVN_FORMAT_RGBA8UI,0);
    mtl_tex_init(&different);mtl_tex_init(&independent);
    CHECK(tex_mtl(&different).heap!=first,"different storage offsets do not alias");
    CHECK(tex_mtl(&independent).heap!=first,"different pools do not alias");
    // Production depth/stencil clears on differently sized aliases, then GPU reads.
    NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(texture2d<uint,access::read> s [[texture(0)]],depth2d<float,access::read> d [[texture(1)]],device uint2 *o [[buffer(0)]],uint2 p [[thread_position_in_grid]]) { o[p.y*d.get_width()+p.x]=uint2(s.read(p).r,as_type<uint>(d.read(p))); }" options:nil error:&error];
    id<MTLComputePipelineState> reader=[g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&error];
    CHECK(reader!=nil,"literal depth/stencil reader compiles");
    id<MTLCommandQueue> q=[g_dev newCommandQueue];tex_t depth[8];
    for(unsigned i=0;i<8;i++) { @autoreleasepool {
        depth[i]=make_tex(&pool,82000+i,128+i*2,96+i,NVN_FORMAT_DEPTH32F_STENCIL8,0x1000000);mtl_tex_init(&depth[i]);
        id<MTLTexture> t=tex_mtl(&depth[i]);CHECK(t.heap!=nil&&t.heap!=first,"depth gets physical storage separate from color");
        state_reset();memset(&R,0,sizeof R);mtl_sub_begin();R.has_rt=1;R.rt.depth=&depth[i];
        struct {op_hdr head;p_clear_ds value;op_hdr end;} ops={0};
        ops.head=(op_hdr){OP_CLEAR_DS,sizeof(op_hdr)+sizeof(p_clear_ds)};ops.value=(p_clear_ds){.depth=.25,.depth_mask=1,.stencil=17+i,.stencil_mask=255};ops.end=(op_hdr){OP_END,sizeof(op_hdr)};
        mtl_exec((const uint8_t *)&ops);mtl_sub_commit();mtl_drain();CHECK(!mtl_last_commit_error(),"production depth clear completes on an alias heap");
        id<MTLTexture> s=[t newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
        id<MTLBuffer> out=[g_dev newBufferWithLength:t.width*t.height*8 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
        [e setComputePipelineState:reader];[e setTexture:s atIndex:0];[e setTexture:t atIndex:1];[e setBuffer:out offset:0 atIndex:0];[e dispatchThreads:MTLSizeMake(t.width,t.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
        CHECK(cb.status==MTLCommandBufferStatusCompleted,"depth and stencil are GPU-readable after the clear");
        uint32_t *p=out.contents;int valid=1;for(NSUInteger n=0;n<t.width*t.height;n++)valid&=p[n*2]==17+i&&p[n*2+1]==0x3e800000;
        CHECK(valid,"all depth and stencil pixels retain their literal values");
    } }
    tex_t ordinary=make_tex(&pool,83000,64,64,NVN_FORMAT_RGBA8,0x2000000);ordinary.d.flags=0;mtl_tex_init(&ordinary);
    CHECK(tex_mtl(&ordinary).heap==nil,"ordinary persistent images retain their independent contents");
    unsigned heaps=g_image_heaps.n;CHECK(heaps>=4,"registry distinguishes pool, offset and format");
    mtl_alias_drop_pool(&pool);CHECK(g_image_heaps.n==1,"pool finalization removes only its own physical allocations");
    mtl_alias_drop_pool(&other_pool);CHECK(g_image_heaps.n==0,"all finalized pools leave an empty heap registry");
    // Use the real NVN pool initialization and mapping path, as ACNH does.
    PFNNVNMEMORYPOOLINITIALIZEPROC initialize=nvn_proc("nvnMemoryPoolInitialize");
    PFNNVNMEMORYPOOLMAPVIRTUALPROC map=nvn_proc("nvnMemoryPoolMapVirtual");
    PFNNVNMEMORYPOOLFINALIZEPROC finalize=nvn_proc("nvnMemoryPoolFinalize");
    NVNmemoryPool mapped={0},sparse={0};
    pool_builder_t builder={.size=8u<<20,.flags=NVN_MEMORY_POOL_FLAGS_VIRTUAL|NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(initialize(&mapped,(const NVNmemoryPoolBuilder *)&builder),"contiguous virtual pool initializes");
    tex_t unmapped=make_tex((pool_t *)&mapped,84000,64,64,NVN_FORMAT_RGBA8UI,0);
    CHECK(image_heap_texture(&unmapped,tex_desc(&unmapped,0))==nil,"unmapped virtual pool cannot allocate a shared image");
    void *backing=calloc(1,builder.size);
    pool_t physical={.magic=MAGIC('P','O','O','L'),.flags=NVN_MEMORY_POOL_FLAGS_PHYSICAL,.mem=backing,.size=builder.size};
    struct { NVNmemoryPool *physical; int64_t poff,voff; uint64_t size; int32_t storage_class,pad; } request={.physical=(NVNmemoryPool *)&physical,.size=builder.size};
    _Static_assert(sizeof request==0x28,"NVN mapping request layout");
    CHECK(map(&mapped,1,(const NVNmappingRequest *)&request),"physical storage maps through production MapVirtual");
    CHECK(((pool_t *)&mapped)->mem==backing&&!nvn_sparse_pool(&mapped),"mapped virtual pool has stable contiguous backing");
    tex_t virtual_images[32];id<MTLHeap> virtual_heap=nil;
    for(unsigned i=0;i<32;i++) {
        virtual_images[i]=make_tex((pool_t *)&mapped,84001+i,1024+i*2,576+i,NVN_FORMAT_RGBA8UI,0);
        mtl_tex_init(&virtual_images[i]);id<MTLTexture> image=tex_mtl(&virtual_images[i]);
        CHECK(image.heap!=nil,"mapped contiguous virtual image uses placement storage");
        if(!virtual_heap)virtual_heap=image.heap;
        CHECK(image.heap==virtual_heap,"virtual resolution variants share physical storage");
    }
    literal_roundtrip(tex_mtl(&virtual_images[0]),9);
    literal_roundtrip(tex_mtl(&virtual_images[31]),43);
    literal_roundtrip(tex_mtl(&virtual_images[0]),71);
    finalize(&mapped);CHECK(g_image_heaps.n==0,"virtual pool finalization drops its shared heaps");free(backing);
    builder.size=DM_GAME_APP_POOL+0x10000ull;
    CHECK(initialize(&sparse,(const NVNmemoryPoolBuilder *)&builder),"sparse virtual pool initializes");
    CHECK(nvn_sparse_pool(&sparse),"large virtual pool uses the sparse page-table path");
    tex_t sparse_image=make_tex((pool_t *)&sparse,85000,64,64,NVN_FORMAT_RGBA8UI,0);
    CHECK(image_heap_texture(&sparse_image,tex_desc(&sparse_image,0))==nil,"sparse virtual images retain their existing storage path");
    finalize(&sparse);CHECK(g_image_heaps.n==0,"sparse finalization leaves no shared heaps");
    printf("image heaps: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
