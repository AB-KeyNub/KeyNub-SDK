require "spec"
require "../src/keynub_licdongle"

describe KeyNub::LicDongle do
  it "names status codes" do
    KeyNub::LicDongle.status_name(-2).should eq "NoDevice"
    KeyNub::LicDongle.status_name(0).should eq "Ok"
    KeyNub::LicDongle.status_name(-99).should eq "Unknown"
  end

  it "builds the error text from operation, status and detail" do
    e = KeyNub::LicDongle::Error.new("licdf_open", -2)
    e.status.should eq KeyNub::LicDongle::Status::NoDevice
    e.code.should eq -2
    e.operation.should eq "licdf_open"
    e.message.should eq "licdf_open: NoDevice (-2)"
    f = KeyNub::LicDongle::Error.new("licdf_record_read", -14, "no such record")
    f.message.should eq "licdf_record_read: NotFound (-14): no such record"
    KeyNub::LicDongle::Error.new("x", -99).status.should be_nil
  end

  it "keeps the bare file name as the last resort" do
    all = KeyNub::LicDongle.library_candidates
    all.should_not be_empty
    unless ENV[KeyNub::LicDongle::LIBRARY_ENVIRONMENT_VARIABLE]?
      all.last.should eq KeyNub::LicDongle.library_basename
    end
  end

  it "reads a NUL-terminated buffer" do
    KeyNub::LicDongle.c_string(Bytes[0x61, 0x62, 0, 0x63]).should eq "ab"
    KeyNub::LicDongle.c_string(Bytes[0x61, 0x62]).should eq "ab"
  end
end
