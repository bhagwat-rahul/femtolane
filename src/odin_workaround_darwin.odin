package main

import "base:intrinsics"

@(init, private = "file")
odin_llvm_error_workaround :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
}
