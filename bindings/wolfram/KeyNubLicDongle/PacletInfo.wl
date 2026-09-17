(* ::Package:: *)

PacletObject[
  <|
    "Name" -> "KeyNub/KeyNubLicDongle",
    "Description" -> "Client for the KeyNub USB license dongle: genuineness check, license records, hardware counters, dongle-bound encryption",
    "Creator" -> "KeyNub <info@keynub.com>",
    "URL" -> "https://www.keynub.com/developers/wolfram/",
    "SourceControlURL" -> "https://github.com/AB-KeyNub/KeyNub-SDK",
    "License" -> "Apache-2.0",
    "PublisherID" -> "KeyNub",
    "Version" -> "1.1.1",
    "WolframVersion" -> "13.1+",
    "PrimaryContext" -> "KeyNub`KeyNubLicDongle`",
    "Extensions" -> {
      {
        "Kernel",
        "Root" -> "Kernel",
        "Context" -> {"KeyNub`KeyNubLicDongle`"},
        "Symbols" -> {
          "KeyNub`KeyNubLicDongle`LicDongleLibraryPath",
          "KeyNub`KeyNubLicDongle`LicDongleLibraryVersion",
          "KeyNub`KeyNubLicDongle`LicDongleDevices",
          "KeyNub`KeyNubLicDongle`LicDongleOpen",
          "KeyNub`KeyNubLicDongle`LicDongleOpenPath",
          "KeyNub`KeyNubLicDongle`LicDongleClose",
          "KeyNub`KeyNubLicDongle`LicDongleInfo",
          "KeyNub`KeyNubLicDongle`LicDongleSerial",
          "KeyNub`KeyNubLicDongle`LicDongleVerifyGenuine",
          "KeyNub`KeyNubLicDongle`LicDongleGenuineQ",
          "KeyNub`KeyNubLicDongle`LicDongleSetTrustRoot",
          "KeyNub`KeyNubLicDongle`LicDongleSessionOpen",
          "KeyNub`KeyNubLicDongle`LicDongleSessionClose",
          "KeyNub`KeyNubLicDongle`LicDongleAuthorizeWrite",
          "KeyNub`KeyNubLicDongle`LicDongleRotateWriteKey",
          "KeyNub`KeyNubLicDongle`LicDongleRecords",
          "KeyNub`KeyNubLicDongle`LicDongleReadRecord",
          "KeyNub`KeyNubLicDongle`LicDongleWriteRecord",
          "KeyNub`KeyNubLicDongle`LicDongleEraseRecord",
          "KeyNub`KeyNubLicDongle`LicDongleEraseAllRecords",
          "KeyNub`KeyNubLicDongle`LicDongleReadCounter",
          "KeyNub`KeyNubLicDongle`LicDongleIncrementCounter",
          "KeyNub`KeyNubLicDongle`LicDongleAppEncrypt",
          "KeyNub`KeyNubLicDongle`LicDongleAppDecrypt",
          "KeyNub`KeyNubLicDongle`LicDongleStatusText",
          "KeyNub`KeyNubLicDongle`LicDongleLastErrorDetail"
        }
      },
      {
        "Documentation",
        "Language" -> "English",
        "MainPage" -> "Guides/KeyNubLicDongle"
      }
    },
    "Keywords" -> {"licensing", "copy protection", "dongle", "USB", "hardware"}
  |>
]
