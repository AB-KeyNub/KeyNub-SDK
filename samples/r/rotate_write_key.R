# KeyNub SDK - R sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
# that from the next session onward only your key can write records, erase them or
# increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#   openssl ecparam -name prime256v1 -genkey -noout |
#     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#   Rscript rotate_write_key.R ../../keys/keynub-shipping-writeauth.key.der my-key.der
#
# Run from the checkout the package finds the native library in
# natives/<platform> on its own; elsewhere set KEYNUB_LICDONGLE_LIBRARY or call
# licd_library() first.
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It cannot be
# recovered from the dongle, and a unit rotated to a key you have lost has to come
# back to be re-provisioned.

library(KeyNubLicDongle)

read_key <- function(path) {
  if (!file.exists(path)) stop("cannot open ", path, call. = FALSE)
  readBin(path, "raw", file.size(path))
}

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  message("usage: Rscript rotate_write_key.R <current-key.der> <new-key.der>")
  quit(status = 2)
}
current <- read_key(args[1])
replacement <- read_key(args[2])

ctx <- licd_context()
if (nrow(licd_enumerate(ctx)) == 0) {
  cat("Connect a KeyNub dongle and re-run.\n")
  licd_close(ctx)
  quit(status = 0)
}

status <- tryCatch({
  dongle <- licd_open(ctx)
  cat(sprintf("Dongle %s\n", licd_serial(dongle)))
  if (licd_info(dongle)$writeauth_rotated) {
    cat("This dongle's write key has already been rotated away from the factory one.\n")
  }

  licd_with_session(dongle, {
    licd_write_auth(dongle, current)           # the key the dongle accepts today
    licd_write_auth_rotate(dongle, replacement) # from the next session: only the new one
  })

  info <- licd_info(dongle)
  cat(sprintf("Write key rotated: %s\n", if (info$writeauth_rotated) "yes" else "no"))
  licd_close(dongle)
  0
}, licd_error = function(e) {
  message("KeyNub error: ", conditionMessage(e))
  1
})

licd_close(ctx)
quit(status = status)
