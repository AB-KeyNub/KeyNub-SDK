# Tests against a stand-in for the C ABI (licd_stub.c beside this file): one
# imaginary dongle held in memory, so every call of the package runs end to end
# without hardware. The stand-in is compiled here with R's own toolchain (R CMD
# SHLIB) and the package is pointed at it through licd_library(). Set
# KEYNUB_LICDONGLE_LIBRARY to an already compiled stand-in to skip the build.
# Without a C compiler the file reports that the stand-in could not be built
# and ends without testing anything; it never fails for that reason, because R
# CMD check may run on a machine that has R but no compiler.

library(KeyNubLicDongle)

check <- function(cond, what) {
  if (!isTRUE(cond)) stop("FAILED: ", what, call. = FALSE)
  invisible(TRUE)
}

# Evaluates expr, requires it to signal an error of the given class, returns it.
expect_error <- function(expr, class, what) {
  err <- tryCatch({
    expr
    NULL
  }, error = function(e) e)
  check(!is.null(err), paste0(what, ": no error was signalled"))
  check(inherits(err, class),
        paste0(what, ": error of class ", paste(class(err), collapse = "/"),
               " is not a ", class))
  invisible(err)
}

build_stub <- function() {
  src <- "licd_stub.c"
  if (!file.exists(src)) return(NULL)
  include <- system.file("include", package = "KeyNubLicDongle")
  if (!file.exists(file.path(include, "licdongle.h"))) return(NULL)
  dir <- tempfile("licd-stub-")
  dir.create(dir)
  dir <- normalizePath(dir, winslash = "/")
  file.copy(src, file.path(dir, "licd_stub.c"))
  lib <- paste0("licd_stub", .Platform$dynlib.ext)
  r <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "R.exe" else "R")
  previous <- Sys.getenv("PKG_CPPFLAGS", unset = NA)
  Sys.setenv(PKG_CPPFLAGS = paste0("-I", shQuote(include), " -DLICD_BUILD_SHARED"))
  on.exit(if (is.na(previous)) Sys.unsetenv("PKG_CPPFLAGS") else Sys.setenv(PKG_CPPFLAGS = previous),
          add = TRUE)
  # Built inside its own directory with bare file names: a Windows path with
  # backslashes does not survive the trip through make and the shell.
  wd <- setwd(dir)
  on.exit(setwd(wd), add = TRUE)
  # R CMD check runs tests with R_TESTS=startup.Rs, a file the nested R that
  # SHLIB starts would look for in this directory and not find.
  tests_env <- Sys.getenv("R_TESTS", unset = NA)
  Sys.unsetenv("R_TESTS")
  on.exit(if (!is.na(tests_env)) Sys.setenv(R_TESTS = tests_env), add = TRUE)
  output <- tryCatch(
    suppressWarnings(system2(r, c("CMD", "SHLIB", "-o", lib, "licd_stub.c"),
                             stdout = TRUE, stderr = TRUE)),
    error = function(e) structure(conditionMessage(e), status = 1L))
  status <- attr(output, "status")
  out <- file.path(dir, lib)
  if ((!is.null(status) && status != 0L) || !file.exists(out)) {
    cat("R CMD SHLIB did not produce the stand-in:\n", paste0("  ", output, "\n"), sep = "")
    return(NULL)
  }
  out
}

FACTORY_KEY <- as.raw(c(0x30, 0x10, 0x01, 0x02, 0x03))
REPLACEMENT_KEY <- as.raw(c(0x30, 0x11, 0x09, 0x08, 0x07, 0x06))
SERIAL <- "04A1B2C3D4E5F6"

# Runs body(ctx, dongle) against the stand-in and always tears down.
with_device <- function(body) {
  ctx <- licd_context()
  on.exit(licd_close(ctx), add = TRUE)
  dongle <- licd_open(ctx)
  on.exit(licd_close(dongle), add = TRUE, after = FALSE)
  body(ctx, dongle)
}

test_status_codes <- function() {
  check(identical(licd_version(), c(9L, 8L, 7L)), "the stand-in reports 9.8.7")
  check(identical(licd_strerror(licd_status_codes[["no_device"]]), "no device"),
        "strerror text")
  texts <- licd_strerror(licd_status_codes)
  check(length(texts) == 21L && all(nzchar(texts)), "every status has a text")

  err <- tryCatch(KeyNubLicDongle:::.licd_stop(-2L, "licd_op", "the detail"),
                  error = function(e) e)
  check(inherits(err, "licd_no_device") && inherits(err, "licd_error"), "condition classes")
  check(identical(err$status, -2L), "status field")
  check(identical(err$operation, "licd_op"), "operation field")
  check(identical(err$detail, "the detail"), "detail field")
  check(identical(conditionMessage(err), "licd_op: no device (the detail)"), "message")
  err <- tryCatch(KeyNubLicDongle:::.licd_stop(-4L, "licd_op"), error = function(e) e)
  check(identical(class(err), c("licd_error", "error", "condition")), "generic failure class")
  check(identical(conditionMessage(err), "licd_op: I/O error"), "message without detail")
}

test_enumerate_and_open <- function() {
  ctx <- licd_context()
  check(licd_is_open(ctx), "a new context is open")
  devices <- licd_enumerate(ctx)
  check(is.data.frame(devices) && nrow(devices) == 1L, "one stand-in device")
  check(identical(devices$serial, SERIAL), "enumerated serial")
  check(identical(devices$path, "stub:0"), "enumerated path")
  check(identical(devices$vendor_id, 0x1234L), "vendor id")
  check(identical(devices$product_id, 0xABCDL), "product id")

  err <- expect_error(licd_open(ctx, "nope"), "licd_no_device", "open with a wrong serial")
  check(identical(err$operation, "licd_open"), "operation of the failed open")
  check(identical(err$detail, "no dongle with that serial"), "detail of the failed open")
  check(identical(licd_error_detail(ctx), "no dongle with that serial"), "licd_error_detail")
  expect_error(licd_open_path(ctx, "stub:9"), "licd_no_device", "open at a wrong path")
  expect_error(licd_open(ctx, 42), "error", "a non-string serial is refused")

  for (dongle in list(licd_open(ctx), licd_open(ctx, SERIAL), licd_open_path(ctx, "stub:0"))) {
    check(licd_is_open(dongle), "an opened dongle is open")
    check(identical(licd_serial(dongle), SERIAL), "serial of the open dongle")
    check(identical(format(dongle), format(dongle)), "the dongle prints")
    licd_close(dongle)
    licd_close(dongle)
    check(!licd_is_open(dongle), "a closed dongle is closed")
    expect_error(licd_serial(dongle), "error", "a closed dongle refuses calls")
  }
  out <- capture.output(print(ctx))
  check(identical(out, "<KeyNub context>"), "the context prints")

  dongle <- licd_open(ctx)
  licd_close(ctx)
  check(!licd_is_open(ctx), "a closed context is closed")
  check(!licd_is_open(dongle), "closing the context closes its dongles")
  expect_error(licd_open(ctx), "error", "a closed context refuses calls")
  licd_close(ctx)
  out <- capture.output(print(dongle))
  check(identical(out, "<KeyNub dongle (closed)>"), "a closed dongle prints as such")
}

test_info_serial_genuine <- function() {
  with_device(function(ctx, dongle) {
    info <- licd_info(dongle)
    check(identical(info$protocol_version, c(1L, 0L)), "protocol version")
    check(identical(info$firmware_version, c(2L, 3L, 4L)), "firmware version")
    check(isTRUE(info$se_ready) && isTRUE(info$provisioned) && isTRUE(info$isolated),
          "flags that are set")
    check(identical(info$data_capacity, 1024 * 1024), "capacity")
    check(identical(info$data_free, 1000000), "free")
    check(identical(info$watchdog_reboot, FALSE), "watchdog flag clear")
    check(identical(info$writeauth_rotated, FALSE), "rotation flag clear")

    result <- licd_verify_genuine(dongle)
    check(isTRUE(result$genuine), "genuine")
    check(identical(result$serial, SERIAL), "certificate serial")
    check(identical(result$provisioned_date, "2026-08-15"), "provisioned date")
    check(isTRUE(licd_is_genuine(dongle)), "licd_is_genuine")
    out <- capture.output(print(dongle))
    check(identical(out, paste0("<KeyNub dongle ", SERIAL, ">")), "an open dongle prints its serial")
  })
}

test_trust_root <- function() {
  with_device(function(ctx, dongle) {
    expect_error(licd_set_trust_root(ctx, raw(0)), "licd_error", "an empty root is refused")
    expect_error(licd_set_trust_root(ctx, as.raw(c(0x02, 0x01, 0x00))), "licd_certificate_invalid",
                 "a non-DER root is refused")
    licd_set_trust_root(ctx, c(as.raw(c(0x30, 0x82, 0x01, 0x00)), rep(as.raw(0xAB), 128)))
    expect_error(licd_verify_genuine(dongle), "licd_certificate_invalid",
                 "verification under a foreign root")
    check(identical(licd_is_genuine(dongle), FALSE), "licd_is_genuine fails closed")
    licd_set_trust_root(ctx, c(as.raw(c(0x30, 0x82, 0x01, 0x00)), rep(as.raw(0x01), 128)))
    check(isTRUE(licd_is_genuine(dongle)), "genuine again under the issuing root")
  })
}

test_records_counters_crypto <- function() {
  with_device(function(ctx, dongle) {
    expect_error(licd_record_list(dongle), "licd_session_expired", "records need a session")
    licd_with_session(dongle, {
      payload <- charToRaw("license-blob-0123456789")
      expect_error(licd_record_write(dongle, "lic", payload), "licd_auth_required",
                   "writing needs the write role")
      expect_error(licd_write_auth(dongle, as.raw(c(0x30, 0x00))), "licd_not_genuine",
                   "a wrong key does not elevate")
      expect_error(licd_write_auth(dongle, raw(0)), "licd_error", "an empty key is refused")
      licd_write_auth(dongle, FACTORY_KEY)
      licd_record_write(dongle, "lic", payload)
      check(identical(licd_record_read(dongle, "lic"), payload), "read back what was written")

      licd_record_write(dongle, "cfg", "cfgdata")
      records <- licd_record_list(dongle)
      check(is.data.frame(records) && nrow(records) == 2L, "two records listed")
      check(identical(sort(records$name), c("cfg", "lic")), "record names")
      check(identical(records$size[records$name == "lic"], as.numeric(length(payload))),
            "record size")
      check(identical(rawToChar(licd_record_read(dongle, "cfg")), "cfgdata"),
            "a string is stored as its bytes")

      expect_error(licd_record_read(dongle, "nope"), "licd_not_found", "reading a missing record")
      expect_error(licd_record_erase(dongle, "nope"), "licd_not_found", "erasing a missing record")
      expect_error(licd_record_erase(dongle, ""), "error", "an empty name never erases")
      check(nrow(licd_record_list(dongle)) == 2L, "nothing was erased by mistake")
      licd_record_erase(dongle, "cfg")
      check(identical(licd_record_list(dongle)$name, "lic"), "one record after the erase")

      licd_record_write(dongle, "empty", raw(0))
      check(identical(licd_record_read(dongle, "empty"), raw(0)), "an empty record reads back empty")

      before <- licd_counter_read(dongle, 0)
      check(identical(licd_counter_increment(dongle, 0), before + 1), "increment returns the new value")
      check(identical(licd_counter_read(dongle, 0), before + 1), "the counter went up by one")
      check(identical(licd_counter_read(dongle, 1L), 0), "counter 1 untouched")
      err <- expect_error(licd_counter_read(dongle, 7), "licd_error", "a counter the dongle lacks")
      check(identical(err$status, licd_status_codes[["range"]]), "range status for counter 7")
      expect_error(licd_counter_read(dongle, -1), "error", "a negative counter id is refused")

      secret <- as.raw((seq(0, 99) * 3 + 7) %% 256)
      for (scope in c("device", "developer")) {
        blob <- licd_app_encrypt(dongle, secret, scope)
        check(length(blob) > length(secret), paste("sealed data is longer, scope", scope))
        check(identical(as.integer(blob[1]), if (scope == "device") 0L else 1L),
              paste("scope byte", scope))
        check(identical(licd_app_decrypt(dongle, blob), secret), paste("round trip, scope", scope))
        tampered <- blob
        tampered[length(tampered)] <- xor(tampered[length(tampered)], as.raw(0x01))
        err <- expect_error(licd_app_decrypt(dongle, tampered), "licd_error", "tampered data")
        check(identical(err$status, licd_status_codes[["tag_mismatch"]]), "tag mismatch status")
      }
      check(identical(rawToChar(licd_app_decrypt(dongle, licd_app_encrypt(dongle, "text"))), "text"),
            "a string round-trips")
      check(identical(licd_app_decrypt(dongle, licd_app_encrypt(dongle, raw(0))), raw(0)),
            "empty data round-trips")
      expect_error(licd_app_encrypt(dongle, secret, "everyone"), "error", "an unknown scope is refused")

      licd_record_erase_all(dongle)
      check(nrow(licd_record_list(dongle)) == 0L, "erase_all leaves nothing")
    })
    expect_error(licd_record_list(dongle), "licd_session_expired", "the session was closed afterwards")
  })
}

test_rotation <- function() {
  with_device(function(ctx, dongle) {
    licd_with_session(dongle, {
      expect_error(licd_write_auth_rotate(dongle, REPLACEMENT_KEY), "licd_auth_required",
                   "rotation needs the write role")
      licd_write_auth(dongle, FACTORY_KEY)
      expect_error(licd_write_auth_rotate(dongle, raw(0)), "licd_error", "an empty replacement key")
      licd_write_auth_rotate(dongle, REPLACEMENT_KEY)
      licd_record_write(dongle, "lic", "still-writable")
    })
    check(isTRUE(licd_info(dongle)$writeauth_rotated), "the rotation flag is set")
    licd_with_session(dongle, {
      expect_error(licd_write_auth(dongle, FACTORY_KEY), "licd_not_genuine",
                   "the factory key no longer elevates")
      licd_write_auth(dongle, REPLACEMENT_KEY)
      licd_record_write(dongle, "lic", "new-key-writes")
      check(identical(rawToChar(licd_record_read(dongle, "lic")), "new-key-writes"),
            "the new key writes")
    })
  })
}

test_progress <- function() {
  with_device(function(ctx, dongle) {
    licd_with_session(dongle, {
      licd_write_auth(dongle, FACTORY_KEY)
      blob <- as.raw((seq(0, 1999) * 31 + 5) %% 256)
      writes <- list()
      licd_record_write(dongle, "big", blob, progress = function(done, total) {
        writes[[length(writes) + 1]] <<- c(done, total)
        TRUE
      })
      check(identical(writes[[length(writes)]], c(2000, 2000)), "write progress reaches the total")
      expect_error(licd_record_write(dongle, "big2", blob, progress = function(done, total) FALSE),
                   "licd_cancelled", "a FALSE from the progress function cancels a write")

      ticks <- list()
      data <- licd_record_read(dongle, "big", progress = function(done, total) {
        ticks[[length(ticks) + 1]] <<- c(done, total)
        TRUE
      })
      check(identical(data, blob), "read with progress returns the data")
      check(length(ticks) == 4L, "one tick per chunk")
      check(identical(ticks[[4]], c(2000, 2000)), "read progress reaches the total")
      expect_error(licd_record_read(dongle, "big", progress = function(done, total) FALSE),
                   "licd_cancelled", "a FALSE from the progress function cancels a read")
      check(identical(licd_record_read(dongle, "big", progress = function(done, total) NULL), blob),
            "a progress function returning NULL continues")
      err <- expect_error(licd_record_read(dongle, "big", progress = function(done, total) stop("boom")),
                          "licd_cancelled", "an error in the progress function cancels")
      check(identical(err$detail, "the progress function signalled an error"), "the detail says why")
      check(identical(licd_record_read(dongle, "big"), blob), "the dongle is usable afterwards")
      expect_error(licd_record_read(dongle, "big", progress = "yes"), "error",
                   "a non-function progress argument is refused")
    })
  })
}

test_closed_handles <- function() {
  ctx <- licd_context()
  dongle <- licd_open(ctx)
  licd_session_open(dongle)
  licd_session_close(dongle)
  licd_session_close(dongle)
  expect_error(licd_record_read(dongle, "lic"), "licd_session_expired",
               "reading after the session closed")
  value <- licd_with_session(dongle, 42)
  check(identical(value, 42), "licd_with_session returns the value of the expression")
  err <- tryCatch(licd_with_session(dongle, stop("inside")), error = function(e) e)
  check(identical(conditionMessage(err), "inside"), "an error inside licd_with_session propagates")
  expect_error(licd_record_list(dongle), "licd_session_expired",
               "the session is closed after an error inside licd_with_session")
  licd_with_session(dongle, licd_close(dongle))
  check(!licd_is_open(dongle), "closing the dongle inside a session is allowed")
  expect_error(licd_record_read(dongle, "lic"), "error", "a closed dongle refuses reads")
  licd_close(ctx)
}

test_collector <- function() {
  leak <- function() {
    ctx <- licd_context()
    dongle <- licd_open(ctx)
    licd_session_open(dongle)
    licd_open(ctx)
    invisible(NULL)
  }
  leak()
  gc()
  gc()
  ctx <- licd_context()
  dongle <- licd_open(ctx)
  rm(ctx)
  gc()
  check(licd_is_open(dongle), "a reachable dongle keeps its context alive")
  check(identical(licd_serial(dongle), SERIAL), "and the dongle still works")
  licd_close(dongle)
  gc()
  check(TRUE, "finalizers ran without incident")
}

run <- function() {
  test_status_codes()
  test_enumerate_and_open()
  test_info_serial_genuine()
  test_trust_root()
  test_records_counters_crypto()
  test_rotation()
  test_progress()
  test_closed_handles()
  test_collector()
  cat("KeyNubLicDongle: every call passed against the ABI stand-in\n")
}

lib <- Sys.getenv("KEYNUB_LICDONGLE_LIBRARY")
if (!nzchar(lib)) lib <- build_stub()
if (is.null(lib)) {
  cat("KeyNubLicDongle: the ABI stand-in could not be compiled here, so the",
      "end-to-end tests did not run\n")
} else {
  licd_library(lib)
  check(identical(licd_library(), lib), "licd_library reports the chosen library")
  run()
  check(identical(licd_library(), lib), "licd_library reports the loaded library")
  expect_error(licd_library("some/other/library"), "error", "a second library is refused")
}
