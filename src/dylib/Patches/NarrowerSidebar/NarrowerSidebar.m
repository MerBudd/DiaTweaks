#import "StdPatch/StdPatch.h"
#import <libkern/OSCacheControl.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach/mach_vm.h>

extern DPPatch DPNarrowerSidebar;

// Dia clamps the sidebar to 190 points in its resize delegate:
//     mov  x8, #0xc00000000000
//     movk x8, #0x4067, lsl #48   ; 190.0
//     fmov d1, x8
//     fmaxnm d0, d0, d1           ; width = max(width, 190)
// The first two words make the double, so 0x4064 and 0x8000 make it 164, as narrow as Arc. The last two are the same.
// It moves between Dia builds, so it's found by those four words, and only used if they're there exactly once.
static const uint32_t DPSidebarClampWide[4] = { 0xd2d80008, 0xf2e80ce8, 0x9e670101, 0x1e616800 };
static const uint32_t DPSidebarClampNarrow[4] = { 0xd2d00008, 0xf2e80c88, 0x9e670101, 0x1e616800 };

static uint32_t *DPSidebarClamp(void) {
    static uint32_t *site;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned long size = 0;
        uint32_t *text = (uint32_t *)getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(0), "__TEXT", "__text", &size);
        NSUInteger found = 0;
        for (NSUInteger i = 0; text && i + 4 <= size / 4; i++)
            if (!memcmp(text + i, DPSidebarClampWide, sizeof DPSidebarClampWide)) found++, site = text + i;
        if (found != 1) site = NULL;
    });
    return site;
}

static BOOL DPIsSidebarClamp(const uint32_t words[4]) {
    return DPSidebarClamp() && memcmp(DPSidebarClamp(), words, 4 * sizeof(uint32_t)) == 0;
}

// __TEXT is read-only. VM_PROT_COPY gives the process its own writable copy of the page, and the copy stays patched after
// the protection goes back to read and execute.
static BOOL DPWriteSidebarClamp(const uint32_t words[4]) {
    uintptr_t page = vm_page_size, address = (uintptr_t)DPSidebarClamp();
    uintptr_t start = address & ~(page - 1), end = (address + 4 * sizeof(uint32_t) + page - 1) & ~(page - 1);
    if (mach_vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return NO;
    memcpy((void *)address, words, 4 * sizeof(uint32_t));
    sys_icache_invalidate((void *)address, 4 * sizeof(uint32_t));
    return mach_vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS;
}

static void DPApplyNarrowerSidebar(DPPatch *patch) {
    BOOL wide = DPIsSidebarClamp(DPSidebarClampWide), narrow = DPIsSidebarClamp(DPSidebarClampNarrow);
    if (!wide && !narrow) return (void)NSLog(@"DiaPatches: Narrower Sidebar found no sidebar clamp to change");
    if (patch->on == narrow) return;
    if (!DPWriteSidebarClamp(patch->on ? DPSidebarClampNarrow : DPSidebarClampWide))
        NSLog(@"DiaPatches: Narrower Sidebar couldn't change the sidebar clamp");
}

// install runs after the saved switches are read, so it also applies the patch at launch. apply handles toggles. A Dia
// whose resize code moved stays off and says so, like a patch whose classes are gone.
static void DPInstallNarrowerSidebar(void) {
    if (!DPIsSidebarClamp(DPSidebarClampWide) && !DPIsSidebarClamp(DPSidebarClampNarrow)) {
        DPNarrowerSidebar.unavailable = YES;
        return (void)NSLog(@"DiaPatches: Narrower Sidebar doesn't know this Dia's resize code, so it stays off");
    }
    DPApplyNarrowerSidebar(&DPNarrowerSidebar);
}

static NSString *DPVerifyNarrowerSidebar(DPPatch *patch) {
    BOOL wide = DPIsSidebarClamp(DPSidebarClampWide), narrow = DPIsSidebarClamp(DPSidebarClampNarrow);
    if (!wide && !narrow) return @"Dia's sidebar clamp isn't where this patch expects it";
    if (patch->on != narrow) return patch->on ? @"the sidebar still stops at 190" : @"the sidebar still stops at 164";
    return nil;
}

DP_PATCH(DPNarrowerSidebar) {
    .key = @"narrowerSidebar",
    .order = 78,
    .title = @"Narrower Sidebar",
    .detail = @"Let the sidebar shrink to 164 points, so favorites sit two to a row.",
    .symbol = @"arrow.left.and.right.square",
    .tint = @"systemTealColor",
    .section = @"Sidebar & Tab Bar",
    .classes = DPClasses(DPDiaSidebarController),
    .install = DPInstallNarrowerSidebar,
    .apply = DPApplyNarrowerSidebar,
    .verify = DPVerifyNarrowerSidebar,
};
