# Plaintext information, authenticity, and the encrypted session.

#' Plaintext device information
#'
#' Reads what the dongle reports without a session.
#'
#' @param dongle A `licd_dongle`.
#' @return A list: `protocol_version` (two integers), `firmware_version` (three
#'   integers), `se_ready` (the secure element responded), `provisioned`
#'   (factory provisioning complete), `data_capacity` and `data_free` (bytes),
#'   `watchdog_reboot`, `isolated` and `writeauth_rotated` (logicals).
#'
#'   `watchdog_reboot` means the dongle's *previous* boot ended in a watchdog
#'   timeout: the firmware hung and reset itself. It is the only trace a field
#'   hang leaves behind and a power cycle clears it, so it is worth logging.
#'
#'   `writeauth_rotated` is `FALSE` while the dongle still accepts the write key
#'   it left the factory with. That key is public, so a dongle in that state
#'   takes writes from anyone holding it; rotate on receipt with
#'   [licd_write_auth_rotate()].
#' @examples
#' \dontrun{
#' info <- licd_info(dongle)
#' info$firmware_version
#' }
#' @export
licd_info <- function(dongle) {
  .check(.Call(C_get_info, .dev_ptr(dongle)), "licd_get_info")
}

#' The dongle's serial
#'
#' @param dongle A `licd_dongle`.
#' @return The serial as a hex string.
#' @export
licd_serial <- function(dongle) {
  .check(.Call(C_get_serial, .dev_ptr(dongle)), "licd_get_serial")
}

#' Prove that a dongle is genuine
#'
#' Verifies the dongle's certificate chain against the trusted root and runs a
#' live challenge-response against the key inside the dongle.
#' `licd_verify_genuine()` signals a condition of class `licd_not_genuine` (or
#' `licd_certificate_invalid`) when the proof fails; `licd_is_genuine()` is the
#' non-signalling form for a gate and **fails closed**: a missing dongle, an I/O
#' error and an invalid certificate all give `FALSE`.
#'
#' Read the SDK's integration security guide before building a check on the
#' answer. `if (!licd_is_genuine(dongle)) stop()` is one line to delete from a
#' program that ships as source; what cannot be deleted is data the program
#' needs and only the dongle can decrypt, see [licd_app_encrypt()].
#'
#' @param dongle A `licd_dongle`.
#' @return `licd_verify_genuine()`: a list with `genuine` (`TRUE`), `serial`
#'   (from the verified certificate) and `provisioned_date` (`"YYYY-MM-DD"`, or
#'   `""`). `licd_is_genuine()`: `TRUE` or `FALSE`.
#' @examples
#' \dontrun{
#' result <- licd_verify_genuine(dongle)
#' result$serial
#' }
#' @export
licd_verify_genuine <- function(dongle) {
  result <- .check(.Call(C_verify_genuine, .dev_ptr(dongle)), "licd_verify_genuine")
  if (!isTRUE(result$genuine)) {
    .licd_stop(licd_status_codes[["not_genuine"]], "licd_verify_genuine", "")
  }
  result
}

#' @rdname licd_verify_genuine
#' @export
licd_is_genuine <- function(dongle) {
  tryCatch({
    licd_verify_genuine(dongle)
    TRUE
  }, error = function(e) FALSE)
}

#' Open and close the encrypted session
#'
#' Records, counters and app-data encryption need a session: an encrypted,
#' authenticated channel to the dongle (P-256 ECDH, HKDF-SHA256, AES-256-GCM).
#' `licd_with_session()` opens one, evaluates `expr` and closes the session
#' afterwards whatever happens.
#'
#' @param dongle A `licd_dongle`.
#' @param expr An expression to evaluate while the session is open.
#' @return `licd_session_open()` and `licd_session_close()`: `NULL`, invisibly.
#'   `licd_with_session()`: the value of `expr`.
#' @examples
#' \dontrun{
#' data <- licd_with_session(dongle, licd_record_read(dongle, "license"))
#' }
#' @export
licd_session_open <- function(dongle) {
  .check(.Call(C_session_open, .dev_ptr(dongle)), "licd_session_open")
  invisible(NULL)
}

#' @rdname licd_session_open
#' @export
licd_session_close <- function(dongle) {
  .check(.Call(C_session_close, .dev_ptr(dongle)), "licd_session_close")
  invisible(NULL)
}

#' @rdname licd_session_open
#' @export
licd_with_session <- function(dongle, expr) {
  licd_session_open(dongle)
  on.exit(if (licd_is_open(dongle)) licd_session_close(dongle), add = TRUE)
  expr
}

#' Elevate to the write role
#'
#' `licd_write_auth()` unlocks writing, erasing and counter increments for the
#' rest of the session with the dongle's write key, a P-256 private key in
#' PKCS#8 DER. This belongs in your licence-issuing tooling; never ship that key
#' in the application your users run. A key the dongle does not accept signals
#' `licd_not_genuine`.
#'
#' `licd_write_auth_rotate()` replaces the dongle's write key with `key`, a key
#' you hold. It needs the write role, so call `licd_write_auth()` with the
#' current key first. That session keeps the write role; from the next session
#' on only the new key elevates, and the old one no longer works on this
#' dongle. Do this once per dongle, when it arrives: the factory key is public.
#'
#' @param dongle A `licd_dongle` with an open session.
#' @param key The key as a raw vector, for example
#'   `readBin(path, "raw", file.size(path))`.
#' @return `NULL`, invisibly.
#' @examples
#' \dontrun{
#' key <- readBin("my-write-key.der", "raw", file.size("my-write-key.der"))
#' licd_with_session(dongle, {
#'   licd_write_auth(dongle, key)
#'   licd_record_write(dongle, "license", "expires 2027-12-31")
#' })
#' }
#' @export
licd_write_auth <- function(dongle, key) {
  .check(.Call(C_write_auth, .dev_ptr(dongle), .as_raw(key, "key")), "licd_write_auth")
  invisible(NULL)
}

#' @rdname licd_write_auth
#' @export
licd_write_auth_rotate <- function(dongle, key) {
  .check(.Call(C_write_auth_rotate, .dev_ptr(dongle), .as_raw(key, "key")),
         "licd_write_auth_rotate")
  invisible(NULL)
}
