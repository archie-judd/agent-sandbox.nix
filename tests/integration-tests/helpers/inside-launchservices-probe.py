#!/usr/bin/env python3
import ctypes
import sys
from ctypes import c_bool, c_char_p, c_int32, c_long, c_uint32, c_void_p

cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
cs = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")

UTF8 = 0x08000100
ROLES_ALL = 0xFFFFFFFF

cf.CFURLCreateFromFileSystemRepresentation.argtypes = [c_void_p, c_char_p, c_long, c_bool]
cf.CFURLCreateFromFileSystemRepresentation.restype = c_void_p
cf.CFURLCreateWithBytes.argtypes = [c_void_p, c_char_p, c_long, c_uint32, c_void_p]
cf.CFURLCreateWithBytes.restype = c_void_p
cf.CFURLGetFileSystemRepresentation.argtypes = [c_void_p, c_bool, c_char_p, c_long]
cf.CFURLGetFileSystemRepresentation.restype = c_bool
cf.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
cf.CFStringCreateWithCString.restype = c_void_p
cf.CFArrayGetCount.argtypes = [c_void_p]
cf.CFArrayGetCount.restype = c_long
cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
cf.CFArrayGetValueAtIndex.restype = c_void_p

cs.LSOpenCFURLRef.argtypes = [c_void_p, c_void_p]
cs.LSOpenCFURLRef.restype = c_int32
cs.LSRegisterURL.argtypes = [c_void_p, c_bool]
cs.LSRegisterURL.restype = c_int32
cs.LSCopyDefaultApplicationURLForURL.argtypes = [c_void_p, c_uint32, c_void_p]
cs.LSCopyDefaultApplicationURLForURL.restype = c_void_p
cs.LSCopyApplicationURLsForBundleIdentifier.argtypes = [c_void_p, c_void_p]
cs.LSCopyApplicationURLsForBundleIdentifier.restype = c_void_p


def file_url(path):
    raw = path.encode()
    return cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), True)


def url(text):
    raw = text.encode()
    return cf.CFURLCreateWithBytes(None, raw, len(raw), UTF8, None)


def url_path(ref):
    buf = ctypes.create_string_buffer(4096)
    if not cf.CFURLGetFileSystemRepresentation(ref, True, buf, len(buf)):
        return "<unprintable>"
    return buf.value.decode()


def main():
    if len(sys.argv) != 3:
        print("usage: inside-launchservices-probe.py open|register|handler|bundle <arg>", file=sys.stderr)
        return 2
    cmd, arg = sys.argv[1], sys.argv[2]
    if cmd == "open":
        status = cs.LSOpenCFURLRef(file_url(arg), None)
        print("LSOpenCFURLRef:", status)
        return 0 if status == 0 else 1
    if cmd == "register":
        status = cs.LSRegisterURL(file_url(arg), True)
        print("LSRegisterURL:", status)
        return 0 if status == 0 else 1
    if cmd == "handler":
        ref = cs.LSCopyDefaultApplicationURLForURL(url(arg), ROLES_ALL, None)
        print("handler:", url_path(ref) if ref else None)
        return 0 if ref else 1
    if cmd == "bundle":
        ident = cf.CFStringCreateWithCString(None, arg.encode(), UTF8)
        refs = cs.LSCopyApplicationURLsForBundleIdentifier(ident, None)
        count = cf.CFArrayGetCount(refs) if refs else 0
        for i in range(count):
            print("bundle:", url_path(cf.CFArrayGetValueAtIndex(refs, i)))
        return 0 if count else 1
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
