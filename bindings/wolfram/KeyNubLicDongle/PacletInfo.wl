(* KeyNub License Dongle: the Wolfram Language paclet. Pure Wolfram Language
   over the SDK's flat C API through ForeignFunctionLoad (Wolfram 13.1 or
   later); the native library is loaded at run time and is not part of the
   paclet. *)
PacletObject[<|
  "Name" -> "KeyNubLicDongle",
  "Version" -> "1.1.1",
  "WolframVersion" -> "13.1+",
  "Description" -> "Client for the KeyNub USB license dongle: verify a genuine dongle, read and write its license records, use its counters, and encrypt data so that only a dongle can decrypt it.",
  "Creator" -> "KeyNub <info@keynub.com>",
  "License" -> "Apache-2.0",
  "URL" -> "https://www.keynub.com/developers/wolfram/",
  "SourceControlURL" -> "https://github.com/AB-KeyNub/KeyNub-SDK",
  "Keywords" -> {"licensing", "copy protection", "dongle", "USB", "hardware"},
  "Extensions" -> {
    {"Kernel", "Root" -> "Kernel", "Context" -> {"KeyNubLicDongle`"}}
  }
|>]
