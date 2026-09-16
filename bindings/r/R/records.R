# Records, counters and app-data envelope encryption. All need a session.

# Bytes for the C side: a raw vector as it is, a single string as its bytes.
.as_raw <- function(x, what) {
  if (is.raw(x)) return(x)
  if (is.null(x)) return(raw(0))
  if (is.character(x) && length(x) == 1L && !is.na(x)) return(charToRaw(x))
  stop(what, " must be a raw vector or a single string", call. = FALSE)
}

.record_name <- function(name) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("the record name must be one non-empty string", call. = FALSE)
  }
  name
}

.progress_arg <- function(progress) {
  if (!is.null(progress) && !is.function(progress)) {
    stop("progress must be a function(done, total) or NULL", call. = FALSE)
  }
  progress
}

#' The records on the dongle
#'
#' @param dongle A `licd_dongle` with an open session.
#' @return A data frame with the columns `name` and `size` (bytes), one row per
#'   record; zero rows when the dongle holds none.
#' @examples
#' \dontrun{
#' licd_with_session(dongle, licd_record_list(dongle))
#' }
#' @export
licd_record_list <- function(dongle) {
  columns <- .check(.Call(C_record_list, .dev_ptr(dongle)), "licd_record_list")
  as.data.frame(columns, stringsAsFactors = FALSE)
}

#' Read, write and erase records
#'
#' Records are named blobs in the dongle's storage; a licence typically is one.
#' Reading needs a session, writing and erasing need the write role
#' ([licd_write_auth()]). `licd_record_write()` replaces the record atomically.
#' A record that does not exist signals `licd_not_found`.
#'
#' `licd_record_erase_all()` is a separate function on purpose: to the C
#' library a missing name means "erase every record", and an accidentally empty
#' variable must not do that.
#'
#' @param dongle A `licd_dongle` with an open session.
#' @param name The record name, a non-empty string.
#' @param data The bytes to store: a raw vector, or a single string for its
#'   bytes.
#' @param progress `NULL`, or a `function(done, total)` called as the transfer
#'   proceeds, both arguments in bytes. Return `FALSE` to cancel, which signals
#'   `licd_cancelled`; an error inside the function cancels as well.
#' @return `licd_record_read()`: the record as a raw vector (`rawToChar()` gives
#'   text back). The others: `NULL`, invisibly.
#' @examples
#' \dontrun{
#' licd_with_session(dongle, {
#'   licence <- rawToChar(licd_record_read(dongle, "license"))
#' })
#' }
#' @export
licd_record_read <- function(dongle, name, progress = NULL) {
  .check(.Call(C_record_read, .dev_ptr(dongle), .record_name(name), .progress_arg(progress)),
         "licd_record_read")
}

#' @rdname licd_record_read
#' @export
licd_record_write <- function(dongle, name, data, progress = NULL) {
  .check(.Call(C_record_write, .dev_ptr(dongle), .record_name(name), .as_raw(data, "data"),
               .progress_arg(progress)), "licd_record_write")
  invisible(NULL)
}

#' @rdname licd_record_read
#' @export
licd_record_erase <- function(dongle, name) {
  .check(.Call(C_record_erase, .dev_ptr(dongle), .record_name(name)), "licd_record_erase")
  invisible(NULL)
}

#' @rdname licd_record_read
#' @export
licd_record_erase_all <- function(dongle) {
  .check(.Call(C_record_erase, .dev_ptr(dongle), NULL), "licd_record_erase")
  invisible(NULL)
}

#' Monotonic counters
#'
#' The dongle holds hardware counters that only ever go up. Reading needs a
#' session; incrementing needs the write role and is irreversible.
#'
#' @param dongle A `licd_dongle` with an open session.
#' @param id The counter, an integer from 0 upwards; the dongle reports
#'   `licd_status_codes[["range"]]` for one it does not have.
#' @return The counter's value (after the increment, for
#'   `licd_counter_increment()`) as a number. Counters are unsigned 32-bit, so
#'   the value is returned as a double.
#' @examples
#' \dontrun{
#' licd_with_session(dongle, licd_counter_read(dongle, 0))
#' }
#' @export
licd_counter_read <- function(dongle, id) {
  .check(.Call(C_counter_read, .dev_ptr(dongle), .counter_id(id)), "licd_counter_read")
}

#' @rdname licd_counter_read
#' @export
licd_counter_increment <- function(dongle, id) {
  .check(.Call(C_counter_increment, .dev_ptr(dongle), .counter_id(id)),
         "licd_counter_increment")
}

.counter_id <- function(id) {
  if (!is.numeric(id) || length(id) != 1L || is.na(id) || id < 0 || id > 255 || id != trunc(id)) {
    stop("id must be one integer from 0 to 255", call. = FALSE)
  }
  as.integer(id)
}

#' Encrypt data that only a dongle can decrypt
#'
#' The pair to build a licence check on. `licd_app_encrypt()` seals `data` so
#' that only a dongle can open it; `licd_app_decrypt()` opens it again. Put
#' something the program genuinely needs through this, such as the parameters
#' of your model, and ship only the sealed form: then removing the check
#' removes the data. Bulk encryption runs on the host; the dongle wraps only a
#' small key.
#'
#' `scope = "developer"` lets any dongle you have issued decrypt the data, so
#' one sealed file serves every customer; `scope = "device"` locks it to the
#' one dongle that sealed it.
#'
#' @param dongle A `licd_dongle` with an open session.
#' @param data The plaintext: a raw vector, or a single string for its bytes.
#' @param packed The sealed data from `licd_app_encrypt()`, a raw vector.
#' @param scope `"device"` or `"developer"`.
#' @return A raw vector: the sealed data, or the recovered plaintext.
#' @examples
#' \dontrun{
#' sealed <- licd_with_session(dongle, licd_app_encrypt(dongle, "the data", "developer"))
#' saveRDS(sealed, "model-parameters.sealed")
#' # In the shipped program:
#' plain <- licd_with_session(dongle, licd_app_decrypt(dongle, readRDS("model-parameters.sealed")))
#' rawToChar(plain)
#' }
#' @export
licd_app_encrypt <- function(dongle, data, scope = c("device", "developer")) {
  scope <- match.arg(scope)
  code <- if (identical(scope, "device")) 0L else 1L
  .check(.Call(C_app_encrypt, .dev_ptr(dongle), code, .as_raw(data, "data")), "licd_app_encrypt")
}

#' @rdname licd_app_encrypt
#' @export
licd_app_decrypt <- function(dongle, packed) {
  if (!is.raw(packed)) stop("packed must be a raw vector", call. = FALSE)
  .check(.Call(C_app_decrypt, .dev_ptr(dongle), packed), "licd_app_decrypt")
}
