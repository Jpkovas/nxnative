# Compressible render-image storage sharing

Set `DM_NVN_ALIAS_HEAPS=1` to try physical sharing of private, single-level,
single-sample 2D compressible images. The default is off. This is not CPU
compression or swap. No profile is changed by this contribution.

Only the same NVN pool, offset, Metal format and power-of-two size class
share a placement heap. Different dimensions retain distinct texture
descriptors. Linear, display and sparse images are excluded. Contiguous
virtual pools must already have backing storage: the existing MapVirtual
path rejects a different backing base. True sparse page-table pools remain
on their existing path.

The heap is one resident allocation, including indirect Metal4 access.
Pool finalization removes its heaps through deferred release. Creation
does not zero an allocation still used by another descriptor; the next
GPU writer initializes the compressible alias in submission order.

Run `make -C dm/gfx/tests GAME=01006F8002326000 t_image_heaps`, then
`MTL_DEBUG_LAYER=1 dm/gfx/tests/t_image_heaps`. Repeat with
`DM_NVN_ENC_THREAD=1` for deferred encoding. The regression uses synthetic
pixels, real NVN contiguous mapping, GPU depth/stencil reads and a sparse
pool exclusion case. It needs no game inputs or translated game shaders.

This remains experimental: arbitrary overlapping offsets, cross-format
aliases and sparse remapping are outside its sharing key. The narrow local
LM3 device result does not establish general NVN alias coherence. A short
ACNH Mac route showed similar resident memory and slightly higher GPU
allocations, so no ACNH memory saving is claimed. Other titles and long
sessions still require testing.
