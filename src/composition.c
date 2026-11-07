// A Direct3D 11 swapchain composed into a Win32 window by DirectComposition,
// with premultiplied alpha, so that where the renderer draws nothing the
// window's system backdrop (Mica, Acrylic) shows, and what it draws covers it.
// A window swapchain's alpha is ignored by DWM; only a composition swapchain
// keeps it.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdlib.h>

// mingw's dcomp.h declares its interfaces for C++ only, so the three calls
// this file makes go through their vtables by index.
typedef struct composition_object { void **vtable; } composition_object;
typedef HRESULT (WINAPI *create_device_fn)(IDXGIDevice *, REFIID, void **);
enum {
    device_commit = 3,
    device_create_target_for_hwnd = 6,
    device_create_visual = 7,
    target_set_root = 3,
    visual_set_content = 15,
};

static const GUID iid_dxgi_device = {0x54ec77fa, 0x1377, 0x44e6, {0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c}};
static const GUID iid_dxgi_factory2 = {0x50c83a1c, 0xe072, 0x4c48, {0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0}};
static const GUID iid_d3d11_texture2d = {0x6f15aaf2, 0xd208, 0x4e89, {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}};
static const GUID iid_composition_device = {0xc37ea93a, 0xe7aa, 0x450d, {0xb1, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3}};

typedef struct zui_sokol_composition {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain1 *swapchain;
    ID3D11RenderTargetView *render_view;
    ID3D11Texture2D *depth_stencil;
    ID3D11DepthStencilView *depth_stencil_view;
    composition_object *composition;
    composition_object *target;
    composition_object *visual;
    HMODULE dcomp_library;
    UINT width, height;
} zui_sokol_composition;

static void release(void *object) {
    if (object) IUnknown_Release((IUnknown *)object);
}

static HRESULT call0(composition_object *object, int index) {
    return ((HRESULT (WINAPI *)(void *))object->vtable[index])(object);
}

static void release_views(zui_sokol_composition *self) {
    release(self->render_view);
    release(self->depth_stencil_view);
    release(self->depth_stencil);
    self->render_view = NULL;
    self->depth_stencil_view = NULL;
    self->depth_stencil = NULL;
}

static HRESULT create_views(zui_sokol_composition *self) {
    ID3D11Texture2D *back_buffer = NULL;
    HRESULT result = IDXGISwapChain1_GetBuffer(self->swapchain, 0, &iid_d3d11_texture2d, (void **)&back_buffer);
    if (FAILED(result)) return result;
    result = ID3D11Device_CreateRenderTargetView(self->device, (ID3D11Resource *)back_buffer, NULL, &self->render_view);
    release(back_buffer);
    if (FAILED(result)) return result;
    D3D11_TEXTURE2D_DESC depth = {
        .Width = self->width,
        .Height = self->height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = DXGI_FORMAT_D24_UNORM_S8_UINT,
        .SampleDesc = {.Count = 1},
        .Usage = D3D11_USAGE_DEFAULT,
        .BindFlags = D3D11_BIND_DEPTH_STENCIL,
    };
    result = ID3D11Device_CreateTexture2D(self->device, &depth, NULL, &self->depth_stencil);
    if (FAILED(result)) return result;
    return ID3D11Device_CreateDepthStencilView(self->device, (ID3D11Resource *)self->depth_stencil, NULL, &self->depth_stencil_view);
}

void zui_sokol_composition_destroy(zui_sokol_composition *self) {
    if (!self) return;
    release_views(self);
    release(self->visual);
    release(self->target);
    release(self->composition);
    release(self->swapchain);
    release(self->context);
    release(self->device);
    if (self->dcomp_library) FreeLibrary(self->dcomp_library);
    free(self);
}

HRESULT zui_sokol_composition_create(HWND hwnd, UINT width, UINT height, zui_sokol_composition **out) {
    *out = NULL;
    zui_sokol_composition *self = calloc(1, sizeof(*self));
    if (!self) return E_OUTOFMEMORY;
    self->width = width ? width : 1;
    self->height = height ? height : 1;

    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory2 *factory = NULL;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    HRESULT result = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &level, 1, D3D11_SDK_VERSION, &self->device, NULL, &self->context);
    if (SUCCEEDED(result)) result = ID3D11Device_QueryInterface(self->device, &iid_dxgi_device, (void **)&dxgi_device);
    if (SUCCEEDED(result)) result = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    if (SUCCEEDED(result)) result = IDXGIAdapter_GetParent(adapter, &iid_dxgi_factory2, (void **)&factory);
    if (SUCCEEDED(result)) {
        DXGI_SWAP_CHAIN_DESC1 description = {
            .Width = self->width,
            .Height = self->height,
            .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .SampleDesc = {.Count = 1},
            .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = DXGI_SCALING_STRETCH,
            .SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED,
        };
        result = IDXGIFactory2_CreateSwapChainForComposition(factory, (IUnknown *)self->device, &description, NULL, &self->swapchain);
    }
    if (SUCCEEDED(result)) {
        self->dcomp_library = LoadLibraryW(L"dcomp.dll");
        create_device_fn create_device = self->dcomp_library ? (create_device_fn)(void *)GetProcAddress(self->dcomp_library, "DCompositionCreateDevice") : NULL;
        result = create_device ? create_device(dxgi_device, &iid_composition_device, (void **)&self->composition) : E_NOINTERFACE;
    }
    if (SUCCEEDED(result)) result = ((HRESULT (WINAPI *)(void *, HWND, BOOL, void **))self->composition->vtable[device_create_target_for_hwnd])(self->composition, hwnd, TRUE, (void **)&self->target);
    if (SUCCEEDED(result)) result = ((HRESULT (WINAPI *)(void *, void **))self->composition->vtable[device_create_visual])(self->composition, (void **)&self->visual);
    if (SUCCEEDED(result)) result = ((HRESULT (WINAPI *)(void *, IUnknown *))self->visual->vtable[visual_set_content])(self->visual, (IUnknown *)self->swapchain);
    if (SUCCEEDED(result)) result = ((HRESULT (WINAPI *)(void *, void *))self->target->vtable[target_set_root])(self->target, self->visual);
    if (SUCCEEDED(result)) result = call0(self->composition, device_commit);
    if (SUCCEEDED(result)) result = create_views(self);
    release(factory);
    release(adapter);
    release(dxgi_device);
    if (FAILED(result)) {
        zui_sokol_composition_destroy(self);
        return result;
    }
    *out = self;
    return S_OK;
}

void *zui_sokol_composition_device(zui_sokol_composition *self) { return self->device; }
void *zui_sokol_composition_device_context(zui_sokol_composition *self) { return self->context; }

// Resizes the buffers to the window's client area when it changed, and
// gives the views to draw this frame into.
HRESULT zui_sokol_composition_frame(zui_sokol_composition *self, UINT width, UINT height, void **render_view, void **depth_stencil_view) {
    width = width ? width : 1;
    height = height ? height : 1;
    if (width != self->width || height != self->height) {
        release_views(self);
        ID3D11DeviceContext_OMSetRenderTargets(self->context, 0, NULL, NULL);
        ID3D11DeviceContext_Flush(self->context);
        HRESULT result = IDXGISwapChain1_ResizeBuffers(self->swapchain, 0, width, height, DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(result)) return result;
        self->width = width;
        self->height = height;
        result = create_views(self);
        if (FAILED(result)) return result;
    }
    *render_view = self->render_view;
    *depth_stencil_view = self->depth_stencil_view;
    return S_OK;
}

HRESULT zui_sokol_composition_present(zui_sokol_composition *self) {
    return IDXGISwapChain1_Present(self->swapchain, 1, 0);
}
