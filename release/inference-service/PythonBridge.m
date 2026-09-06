#import <Foundation/Foundation.h>
#include <Python.h>
#include <dlfcn.h>
#include <unistd.h>

// The C API is resolved only from the runtime sealed inside this service.
// There is no executable path, module name, environment or code in the RPC.
int MuesliRunPython(NSString *runtime, NSString *operation, NSString *source, NSString *model,
                   int input, int output, int diagnostics) {
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 || dup2(diagnostics, STDERR_FILENO) < 0) return 74;
    NSString *library = [runtime stringByAppendingPathComponent:@"lib/libpython3.12.dylib"];
    void *python = dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!python) { dprintf(STDERR_FILENO, "Bundled Python load failed: %s\n", dlerror()); return 70; }
#define API(name) __typeof__(name) *fn_##name = dlsym(python, #name); if (!fn_##name) return 70
    API(PyConfig_InitIsolatedConfig); API(PyConfig_Clear); API(PyConfig_SetBytesString);
    API(PyConfig_SetBytesArgv); API(PyWideStringList_Append); API(Py_InitializeFromConfig);
    API(PyRun_SimpleStringFlags); API(Py_DecodeLocale); API(PyMem_RawFree);
    API(PyPreConfig_InitIsolatedConfig); API(Py_PreInitialize);
    PyPreConfig preconfig;
    fn_PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus prestatus = fn_Py_PreInitialize(&preconfig);
    if (prestatus._type != 0) return 70;
    PyConfig config;
    fn_PyConfig_InitIsolatedConfig(&config);
    config.use_environment = 0; config.user_site_directory = 0; config.site_import = 0;
    config.write_bytecode = 0; config.install_signal_handlers = 0;
    config.buffered_stdio = 0;
    config.module_search_paths_set = 1;
    for (NSString *relative in @[@"lib/python3.12", @"lib/python3.12/lib-dynload", @"lib/python3.12/site-packages"]) {
        wchar_t *wide = fn_Py_DecodeLocale([runtime stringByAppendingPathComponent:relative].fileSystemRepresentation, NULL);
        if (!wide) { fn_PyConfig_Clear(&config); return 70; }
        PyStatus status = fn_PyWideStringList_Append(&config.module_search_paths, wide);
        fn_PyMem_RawFree(wide);
        if (status._type != 0) { fn_PyConfig_Clear(&config); return 70; }
    }
    PyStatus status = fn_PyConfig_SetBytesString(&config, &config.home, runtime.fileSystemRepresentation);
    if (status._type != 0) { fn_PyConfig_Clear(&config); return 70; }
    NSString *executable = [NSBundle.mainBundle.executablePath copy];
    status = fn_PyConfig_SetBytesString(&config, &config.executable, executable.fileSystemRepresentation);
    if (status._type != 0) { fn_PyConfig_Clear(&config); return 70; }
    char *arguments[] = {"muesli-inference", (char *)operation.UTF8String, (char *)source.fileSystemRepresentation, (char *)model.fileSystemRepresentation};
    status = fn_PyConfig_SetBytesArgv(&config, 4, arguments);
    if (status._type != 0) { fn_PyConfig_Clear(&config); return 70; }
    // Use the sandbox's writable home/temp, never the sealed package tree.
    setenv("HOME", NSHomeDirectory().fileSystemRepresentation, 1);
    setenv("TMPDIR", NSTemporaryDirectory().fileSystemRepresentation, 1);
    setenv("PATH", [runtime stringByAppendingPathComponent:@"tools"].fileSystemRepresentation, 1);
    setenv("MUESLI_ALLOW_MODEL_DOWNLOADS", "0", 1);
    setenv("HF_HUB_OFFLINE", "1", 1);
    setenv("HF_HUB_DISABLE_TELEMETRY", "1", 1);
    status = fn_Py_InitializeFromConfig(&config);
    fn_PyConfig_Clear(&config);
    if (status._type != 0) { dprintf(STDERR_FILENO, "Python initialization failed\n"); return 70; }
    int result = fn_PyRun_SimpleStringFlags("from diarise_transcribe.xpc_entry import main\nmain()\n", NULL);
    return result == 0 ? 0 : 1;
}
