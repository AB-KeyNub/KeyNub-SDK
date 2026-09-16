# KeyNub dongle check from R: enumerate -> open -> verify -> session ->
# read a record -> app-crypto round trip.
#
#   Rscript verify_and_read.R
#
# The package comes from CRAN (install.packages("KeyNubLicDongle")) or from this
# checkout (R CMD INSTALL ../../bindings/r). Run from the checkout it finds the
# native library in natives/<platform> on its own; elsewhere set
# KEYNUB_LICDONGLE_LIBRARY or call licd_library() first.
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# READ FIRST: docs/integration-security.md. This sample prints whether the dongle
# is genuine, which is the one thing a real licence check must not do: a printed
# boolean is a deleted line away from nothing. protect_something() shows the shape
# that actually protects something. For an R package that is usually easy,
# because the valuable part is normally data: fitted parameters, a correlation
# set, a proprietary model's coefficients.

library(KeyNubLicDongle)

report <- function(dongle) {
  info <- licd_info(dongle)
  cat(sprintf("Protocol v%d.%d, firmware v%d.%d.%d, %.0f of %.0f bytes free.\n",
              info$protocol_version[1], info$protocol_version[2],
              info$firmware_version[1], info$firmware_version[2], info$firmware_version[3],
              info$data_free, info$data_capacity))

  if (info$watchdog_reboot) {
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    cat("WARNING: this dongle's previous boot ended in a watchdog reset.\n")
  }

  result <- licd_verify_genuine(dongle)
  cat(sprintf("Genuine: %s (serial %s, provisioned %s)\n",
              if (result$genuine) "true" else "false", result$serial, result$provisioned_date))
}

read_records <- function(dongle) {
  records <- licd_record_list(dongle)
  cat(sprintf("%d record(s) on the dongle:\n", nrow(records)))
  for (i in seq_len(nrow(records))) {
    cat(sprintf("  %-16s %6.0f bytes\n", records$name[i], records$size[i]))
  }

  # A missing record is a normal state, not an error.
  if ("license" %in% records$name) {
    data <- licd_record_read(dongle, "license")
    cat(sprintf("Read %d bytes from the license record.\n", length(data)))
  }
}

# The part that actually protects something. At licence-issue time you would call
# licd_app_encrypt() once, with a developer dongle, and ship only the sealed
# data; the program then cannot proceed without a dongle, because it holds no
# other copy. scope = "developer" lets any dongle you have issued decrypt it, so
# one file serves every customer; "device" locks it to one dongle.
protect_something <- function(dongle) {
  needed <- "the data this program cannot run without"

  sealed <- licd_app_encrypt(dongle, needed, scope = "developer")
  recovered <- rawToChar(licd_app_decrypt(dongle, sealed))

  cat(sprintf("App-crypto round trip: %d bytes -> %d sealed -> %s\n",
              nchar(needed), length(sealed),
              if (identical(recovered, needed)) "recovered intact" else "MISMATCH"))
}

version <- licd_version()
cat(sprintf("KeyNub SDK %d.%d.%d (%s)\n", version[1], version[2], version[3], licd_library()))

ctx <- licd_context()
dongles <- licd_enumerate(ctx)
cat(sprintf("Found %d KeyNub dongle(s).\n", nrow(dongles)))
for (i in seq_len(nrow(dongles))) {
  cat(sprintf("  [%d] serial %s\n", i - 1, dongles$serial[i]))
}
if (nrow(dongles) == 0) {
  cat("No dongle attached; nothing to do.\n")
  licd_close(ctx)
  quit(status = 0)
}

# Every call signals a licd_error on failure, so one handler covers them all.
# The condition's detail is what tells "no dongle" from "certificate rejected".
status <- tryCatch({
  dongle <- licd_open(ctx)                   # first dongle, or licd_open(ctx, serial)
  report(dongle)
  licd_with_session(dongle, {
    read_records(dongle)
    protect_something(dongle)
  })
  licd_close(dongle)
  0
}, licd_error = function(e) {
  message("KeyNub error: ", conditionMessage(e))
  1
})

licd_close(ctx)
quit(status = status)
