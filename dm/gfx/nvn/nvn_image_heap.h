// Experimental physical aliasing of compressible render images at an identical
// NVN pool offset. Different dimensions keep distinct Metal texture descriptors.
// Images with different origins/formats never share a heap. Size classes bound
// growth without relocating any allocation still referenced by submitted work.
typedef struct { uint64_t pool; int64_t off; uint64_t capacity; uint32_t format, pad; } image_heap_key;
@interface NvImageHeap : NSObject { @public id<MTLHeap> heap; } @end
@implementation NvImageHeap
- (void)dealloc { res_remove((id<MTLResource>)heap); }
@end
static nvn_hmap g_image_heaps = {.klen = sizeof(image_heap_key)};
int nvn_sparse_pool(const void *pool);
static int image_heap_enabled(void) {
    static int on = -1;
    if (on < 0) { const char *v = getenv("DM_NVN_ALIAS_HEAPS"); on = v && atoi(v) == 1; }
    return on;
}
static id<MTLTexture> image_heap_texture(const tex_t *t, MTLTextureDescriptor *desc) {
    if (!image_heap_enabled() || !t->pool || !(t->d.flags & NVN_TEXTURE_FLAGS_COMPRESSIBLE)
        || (t->d.flags & (NVN_TEXTURE_FLAGS_DISPLAY | NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET | NVN_TEXTURE_FLAGS_SPARSE))
        || ((t->pool->flags & NVN_MEMORY_POOL_FLAGS_VIRTUAL) && (!t->pool->mem || nvn_sparse_pool(t->pool)))
        || desc.textureType != MTLTextureType2D
        || desc.mipmapLevelCount != 1 || desc.sampleCount != 1 || desc.storageMode != MTLStorageModePrivate) return nil;
    // Later reinterpretation must stay on this allocation instead of upgrading
    // the texture into another standalone copy.
    // A non-sparse virtual pool has one fixed contiguous backing address:
    // MapVirtual rejects a different base. Its pool offsets are stable too.
    MTLTextureUsage usage = desc.usage;
    desc.usage |= MTLTextureUsagePixelFormatView;
    MTLSizeAndAlign need = [g_dev heapTextureSizeAndAlignWithDescriptor:desc];
    if (!need.size || need.size > (64u << 20)) { desc.usage = usage; return nil; }
    NSUInteger capacity = 1; while (capacity < need.size) capacity *= 2;
    image_heap_key key; memset(&key, 0, sizeof key);
    key.pool = (uint64_t)(uintptr_t)t->pool; key.off = t->off; key.capacity = capacity; key.format = (uint32_t)desc.pixelFormat;
    pthread_mutex_lock(&g_smu);
    NvImageHeap *entry = hm_get_id(&g_image_heaps, &key);
    if (!entry) {
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement;
        hd.storageMode = desc.storageMode; hd.cpuCacheMode = desc.cpuCacheMode; hd.hazardTrackingMode = MTLHazardTrackingModeTracked; hd.size = capacity;
        entry = [NvImageHeap new]; entry->heap = [g_dev newHeapWithDescriptor:hd];
        if (!entry->heap) MDIE("cannot allocate image alias heap (%lu bytes)", (unsigned long)capacity);
        res_add((id<MTLResource>)entry->heap);
        hm_put_id(&g_image_heaps, &key, entry);
    }
    id<MTLTexture> result = [entry->heap newTextureWithDescriptor:desc offset:0];
    pthread_mutex_unlock(&g_smu);
    if (!result) MDIE("cannot create image in alias heap (%lux%lu format %lu)", (unsigned long)desc.width, (unsigned long)desc.height, (unsigned long)desc.pixelFormat);
    return result;
}
static void image_heaps_drop_pool(const void *pool) {
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_image_heaps.cap;) {
        if (!g_image_heaps.vals[i]) { i++; continue; }
        image_heap_key key; memcpy(&key, g_image_heaps.keys + (size_t)i * sizeof key, sizeof key);
        if (key.pool != (uint64_t)(uintptr_t)pool) { i++; continue; }
        id entry = CFBridgingRelease(nvn_hm_del(&g_image_heaps, &key));
        defer_obj_unref(entry);
    }
    pthread_mutex_unlock(&g_smu);
}
