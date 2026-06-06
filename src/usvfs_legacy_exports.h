#ifndef USVFS_LEGACY_EXPORTS_H
#define USVFS_LEGACY_EXPORTS_H

#include <Windows.h>
#include <cstddef>

extern "C" {
void WINAPI InitLogging(bool toConsole);
bool WINAPI GetLogMessages(LPSTR buffer, size_t size, bool blocking);
void WINAPI DisconnectVFS();
void WINAPI ClearVirtualMappings();
BOOL WINAPI GetVFSProcessList2(size_t* count, DWORD** buffer);
BOOL WINAPI VirtualLinkFile(LPCWSTR source, LPCWSTR destination, unsigned int flags);
BOOL WINAPI VirtualLinkDirectoryStatic(LPCWSTR source, LPCWSTR destination,
                                       unsigned int flags);
void WINAPI ClearExecutableBlacklist();
void WINAPI BlacklistExecutable(LPWSTR executableName);
void WINAPI ClearLibraryForceLoads();
void WINAPI ForceLoadLibrary(LPWSTR processName, LPWSTR libraryPath);
BOOL WINAPI CreateProcessHooked(LPCWSTR lpApplicationName, LPWSTR lpCommandLine,
                                LPSECURITY_ATTRIBUTES lpProcessAttributes,
                                LPSECURITY_ATTRIBUTES lpThreadAttributes,
                                BOOL bInheritHandles, DWORD dwCreationFlags,
                                LPVOID lpEnvironment, LPCWSTR lpCurrentDirectory,
                                LPSTARTUPINFOW lpStartupInfo,
                                LPPROCESS_INFORMATION lpProcessInformation);
}

#endif  // USVFS_LEGACY_EXPORTS_H
