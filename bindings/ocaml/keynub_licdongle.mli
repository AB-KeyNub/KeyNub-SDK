(** KeyNub License Dongle for OCaml.

    Calls the SDK's flat companion API ([keynub_licdongle_flat]) through
    [ctypes-foreign], resolving the functions from the library loaded at run
    time, so nothing is linked at build time. Byte data is [string]; every
    failure raises {!Error} with the library's status code, the operation and
    its diagnostic detail.

    {[
      let secret =
        Keynub_licdongle.with_dongle (fun d ->
          ignore (Keynub_licdongle.verify_genuine d);          (* raises unless genuine *)
          Keynub_licdongle.with_session d (fun () ->
            Keynub_licdongle.app_decrypt d sealed))           (* build the licence check on this *)
    ]} *)

(** {1 Failures} *)

(** The library's status codes, by name. *)
type status =
  | Invalid_arg
  | No_device
  | Access_denied
  | Io
  | Timeout
  | Protocol
  | Not_genuine
  | Cert_invalid
  | Session_expired
  | Tag_mismatch
  | Range
  | Storage_full
  | Busy
  | Not_found
  | Auth_required
  | Firmware_incompatible
  | Sdk_too_old
  | Cancelled
  | Not_implemented
  | Internal
  | Unknown of int  (** a code this binding does not know *)

val status_of_code : int -> status
val status_to_string : status -> string

(** A failed call: the status, its raw code, the C function that failed and
    the library's diagnostic detail for it (often empty). *)
exception Error of { status : status; code : int; operation : string; detail : string }

(** Loading problems: no library found, or one without the expected functions. *)
exception Library_error of string

(** {1 The native library} *)

(** [(major, minor, patch)] of the loaded native library; loads it if no
    other call has. *)
val library_version : unit -> int * int * int

(** The library in use, or the one the next call would load. *)
val library_path : unit -> string

(** The library in use, once one is loaded. *)
val loaded_library_path : unit -> string option

(** Names the native library to load. Call it before the first call; once a
    library is loaded, naming a different one raises {!Library_error}. *)
val set_library_path : string -> unit

(** The library's text for a status code. *)
val status_text : int -> string

(** {1 Dongles} *)

(** An attached dongle, as listed by {!devices}. *)
type device = { serial : string;  (** the serial, as hex *)
                path : string  (** the device path {!open_path} takes *) }

val devices : unit -> device list

(** An open dongle. The library holds up to 32 at a time; release them with
    {!close} or use {!with_dongle}. *)
type dongle

(** Opens the first dongle. *)
val open_first : unit -> dongle

(** Opens the dongle with that serial (an empty serial means the first one). *)
val open_serial : string -> dongle

(** Opens the dongle at a device path from {!devices}. *)
val open_path : string -> dongle

(** Releases a dongle; its session ends with it. *)
val close : dongle -> unit

(** Opens a dongle (the first, or the one with [serial]), runs the function,
    and closes the dongle on every exit path. *)
val with_dongle : ?serial:string -> (dongle -> 'a) -> 'a

(** The dongle's serial, as hex. *)
val serial : dongle -> string

(** Plaintext device information, read without a session. *)
type info = {
  protocol_version : int * int;
  firmware_version : int * int * int;
  secure_element_ready : bool;
  provisioned : bool;
  watchdog_reboot : bool;  (** the previous boot ended in a watchdog reset *)
  isolated : bool;
  write_auth_rotated : bool;  (** {!rotate_write_key} has replaced the shipped write key *)
  data_capacity : int;  (** record storage, bytes *)
  data_free : int;
}

val info : dongle -> info

(** The library's diagnostic detail for the most recent failure on a dongle. *)
val last_error_detail : dongle -> string

(** {1 Authenticity} *)

(** What a genuine dongle proves: the serial from its certificate and the day
    it was personalised ([YYYY-MM-DD], or empty). *)
type genuine = { genuine_serial : string; provisioned_date : string }

(** Proves that the dongle is genuine: certificate chain to the trusted root
    and a live challenge-response. Raises unless it is. *)
val verify_genuine : dongle -> genuine

(** [true] only when the dongle proves genuine. Every failure, of any kind,
    gives [false]. *)
val is_genuine : dongle -> bool

(** Replaces the CA root that {!verify_genuine} checks against (a certificate
    in DER form). Applications do not need this. *)
val set_trust_root : dongle -> string -> unit

(** {1 Session} *)

(** Opens the encrypted session that records, counters and application-data
    encryption need. *)
val session_open : dongle -> unit

(** Ends the session; the write role ends with it. *)
val session_close : dongle -> unit

(** Runs the function inside a session, closing it on every exit path. *)
val with_session : dongle -> (unit -> 'a) -> 'a

(** Elevates the session to the write role with the dongle's write key, a
    P-256 private key in PKCS#8 DER form. *)
val authorize_write : dongle -> string -> unit

(** Replaces the dongle's write key with the given one (P-256, PKCS#8 DER).
    From the next session on, only that key elevates. Needs the write role. *)
val rotate_write_key : dongle -> string -> unit

(** {1 Records} *)

type record_info = { name : string; size : int }

(** The records on the dongle. Needs a session. *)
val records : dongle -> record_info list

(** Reads a record. Needs a session. *)
val read_record : dongle -> string -> string

(** Replaces (or creates) a record. Needs the write role. *)
val write_record : dongle -> string -> string -> unit

(** Erases one record. Needs the write role. An empty name is refused; use
    {!erase_all_records} to erase everything. *)
val erase_record : dongle -> string -> unit

(** Erases every record. Needs the write role. *)
val erase_all_records : dongle -> unit

(** {1 Counters} *)

(** Reads a hardware monotonic counter (0 or 1). Needs a session. *)
val read_counter : dongle -> int -> int

(** Increments a counter, irreversibly, and gives the new value. Needs the
    write role. *)
val increment_counter : dongle -> int -> int

(** {1 Application data} *)

(** Who can decrypt data sealed with {!app_encrypt}. *)
type scope =
  | Device_scope  (** only the dongle that sealed it *)
  | Developer_scope  (** any dongle issued to the same developer *)

(** Seals data so that only a dongle can open it. Needs a session. This is the
    pair to build a licence check on: route something the program needs
    through it, so that removing the check removes the data. *)
val app_encrypt : dongle -> scope -> string -> string

(** Opens data sealed with {!app_encrypt}. Needs a session. *)
val app_decrypt : dongle -> string -> string
