// The C module the Swift package imports: only the SDK's public header, so
// that Swift sees the C structures with the layout the C compiler gives them.
// The functions themselves are loaded at run time (see Library.swift), so
// nothing is linked here and this file exists because a C target needs one.
#include "licdongle.h"
