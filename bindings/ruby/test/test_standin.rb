# frozen_string_literal: true

# Every call of the binding against a stand-in for the C ABI
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory),
# compiled into a shared library with a C compiler from the path (cc, gcc,
# clang, zig cc or cl). KEYNUB_LICDONGLE_LIBRARY naming an already compiled
# stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
# does not run inside a clone.
#
#     ruby test/test_standin.rb        (from bindings/ruby)

require 'minitest/autorun'
require 'fiddle'
require 'rbconfig'
require 'tmpdir'

module StandIn
  module_function

  def sdk_root
    given = ENV.fetch('KEYNUB_SDK_ROOT', '')
    return given unless given.empty?

    dir = Dir.pwd
    loop do
      return dir if File.file?(File.join(dir, 'bindings', 'flat', 'licd_flat.c'))

      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    abort 'the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT'
  end

  def build
    root = sdk_root
    windows = RbConfig::CONFIG['host_os'].match?(/mswin|mingw|cygwin/)
    tmp = Dir.tmpdir
    # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
    # name even for an absolute-path dlopen, and a build tree on that path holds
    # the real library under that name.
    output = File.join(tmp, windows ? 'keynub_licdongle_standin.dll' : 'libkeynub_licdongle_standin.so')
    include = File.join(root, 'core', 'include')
    include = File.join(root, 'include') unless File.file?(File.join(include, 'licdongle.h'))
    source = File.join(root, 'bindings', 'julia', 'test', 'stub', 'licd_stub.c')
    gcc = ['-shared', '-O1', '-DLICD_BUILD_SHARED', "-I#{include}", '-o', output, source]
    gcc << '-fPIC' unless windows
    cl = ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', "/I#{include}", "/Fe:#{output}", source]
    [['cc', *gcc], ['gcc', *gcc], ['clang', *gcc], ['zig', 'cc', *gcc], ['cl', *cl]].each do |command|
      # In the temporary folder, where the compilers leave their byproducts.
      ok = system(*command, chdir: tmp, out: File::NULL, err: File::NULL)
      return output if ok && File.file?(output)
    end
    abort 'the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path'
  end
end

# The library is chosen when the binding is first loaded, once per process, so
# this file runs in a process of its own.
if defined?(KeyNubLicDongle::Native)
  abort 'the binding is already loaded in this process; run this file in a process of its own'
end
ENV['KEYNUB_LICDONGLE_LIBRARY'] = StandIn.build if ENV.fetch('KEYNUB_LICDONGLE_LIBRARY', '').empty?
require_relative '../lib/keynub_licdongle'

SERIAL = '04A1B2C3D4E5F6'
FACTORY_KEY = [0x30, 0x10, 0x01, 0x02, 0x03].pack('C*')
REPLACEMENT_KEY = [0x30, 0x11, 0x09, 0x08, 0x07, 0x06].pack('C*')

class TestStandIn < Minitest::Test
  K = KeyNubLicDongle

  def setup
    @ctx = K::Context.new
    @dongle = @ctx.open
  end

  def teardown
    @dongle.close
    @ctx.close
  end

  def assert_status(error_class, status, &block)
    err = assert_raises(error_class, &block)
    assert_equal status, err.status
    err
  end

  def authorized_session
    session = @dongle.session
    session.authorize_write(FACTORY_KEY)
    session
  end

  def test_library_version
    assert_equal [9, 8, 7], K::Context.library_version
  end

  def test_status_text_and_detail
    assert_equal(-2, K::Status::NO_DEVICE)
    err = assert_status(K::DeviceNotFoundError, K::Status::NO_DEVICE) { @ctx.open('nope') }
    assert_equal 'licd_open: no device (no dongle with that serial)', err.message
    assert_equal 'licd_open', err.operation
    assert_equal 'no dongle with that serial', err.detail
    assert_equal 'no dongle with that serial', @ctx.last_error_detail
  end

  def test_devices
    assert_equal [{ serial: SERIAL, path: 'stub:0', vendor_id: 0x1234, product_id: 0xABCD }], @ctx.enumerate
    assert_status(K::DeviceNotFoundError, K::Status::NO_DEVICE) { @ctx.open('nope') }
    assert_status(K::DeviceNotFoundError, K::Status::NO_DEVICE) { @ctx.open_path('stub:9') }
    by_serial = @ctx.open(SERIAL)
    assert_equal SERIAL, by_serial.serial
    by_serial.close
    by_path = @ctx.open_path('stub:0')
    assert_equal SERIAL, by_path.serial
    by_path.close
  end

  def test_info
    assert_equal SERIAL, @dongle.serial
    assert_same @ctx, @dongle.context
    expected = {
      protocol_version: [1, 0], firmware_version: [2, 3, 4], se_ready: true, provisioned: true,
      data_capacity: 1024 * 1024, data_free: 1_000_000, watchdog_reboot: false, isolated: true,
      writeauth_rotated: false
    }
    assert_equal expected, @dongle.info
  end

  def test_genuine_and_trust_root
    assert_equal({ genuine: true, serial: SERIAL, provisioned_date: '2026-08-15' }, @dongle.verify_genuine!)
    assert @dongle.genuine?
    assert_status(K::CertificateInvalidError, K::Status::CERTIFICATE_INVALID) do
      @ctx.trust_root = [0x02, 0x01, 0x00].pack('C*')
    end
    assert_status(K::Error, K::Status::INVALID_ARGUMENT) { @ctx.trust_root = '' }
    @ctx.trust_root = ([0x30, 0x82, 0x01, 0x00] + Array.new(128, 0xAB)).pack('C*')
    assert_status(K::CertificateInvalidError, K::Status::CERTIFICATE_INVALID) { @dongle.verify_genuine! }
    refute @dongle.genuine?, 'genuine? fails closed'
    @ctx.trust_root = ([0x30, 0x82, 0x01, 0x00] + Array.new(128, 0x01)).pack('C*')
    assert @dongle.genuine?, 'genuine? after the right root'
  end

  def test_session_required
    # A second Session object ends the dongle's session under the first one.
    first = @dongle.session
    second = @dongle.open_session
    second.close
    assert_status(K::SessionExpiredError, K::Status::SESSION_EXPIRED) { first.list_records }
    first.close
    assert first.closed?
    assert_status(K::SessionExpiredError, K::Status::SESSION_EXPIRED) { first.list_records }
    first.close # idempotent
  end

  def test_write_role
    @dongle.session do |s|
      assert_status(K::WriteAuthorizationRequiredError, K::Status::AUTH_REQUIRED) { s.write_record('lic', 'x') }
      assert_status(K::WriteAuthorizationRequiredError, K::Status::AUTH_REQUIRED) { s.increment_counter(0) }
      assert_status(K::NotGenuineError, K::Status::NOT_GENUINE) { s.authorize_write([0x30, 0x00].pack('C*')) }
      s.authorize_write(FACTORY_KEY)
      s.write_record('lic', 'x')
    end
  end

  def test_records
    s = authorized_session
    payload = 'license-blob-0123456789'
    s.write_record('lic', payload)
    assert_equal payload.b, s.read_record('lic')
    assert_equal Encoding::BINARY, s.read_record('lic').encoding
    s.write_record('cfg', 'cfgdata')
    recs = s.list_records
    assert_equal %w[cfg lic], recs.map { |r| r[:name] }.sort
    assert_includes recs, { name: 'lic', size: payload.bytesize }
    assert_equal 'cfgdata'.b, s.read_record('cfg')
    assert_status(K::RecordNotFoundError, K::Status::NOT_FOUND) { s.read_record('nope') }
    assert_status(K::RecordNotFoundError, K::Status::NOT_FOUND) { s.erase_record('nope') }
    assert_raises(ArgumentError) { s.erase_record('') }
    assert_raises(ArgumentError) { s.erase_record(nil) }
    assert_raises(ArgumentError) { s.read_record('') }
    assert_equal 2, s.list_records.length
    s.erase_record('cfg')
    assert_equal ['lic'], s.list_records.map { |r| r[:name] }
    s.write_record('empty', '')
    assert_equal '', s.read_record('empty')
    big = Array.new(2000) { |k| ((k * 31) + 5) & 0xFF }.pack('C*')
    s.write_record('big', big)
    assert_equal big, s.read_record('big')
    s.erase_all_records
    assert_empty s.list_records
    s.close
  end

  def test_progress_and_cancellation
    s = authorized_session
    big = Array.new(2000) { |k| ((k * 31) + 5) & 0xFF }.pack('C*')
    writes = []
    s.write_record('big', big) { |done, total| writes << [done, total] }
    assert_equal [2000, 2000], writes.last
    reads = []
    data = s.read_record('big') do |done, total|
      reads << [done, total]
      true
    end
    assert_equal big, data
    assert_equal [2000, 2000], reads.last
    assert_status(K::OperationCancelledError, K::Status::CANCELLED) { s.read_record('big') { false } }
    assert_status(K::OperationCancelledError, K::Status::CANCELLED) { s.write_record('big', big) { false } }
    boom = Class.new(StandardError)
    err = assert_raises(boom) { s.read_record('big') { raise boom, 'callback exploded' } }
    assert_equal 'callback exploded', err.message
    assert_equal big, s.read_record('big') { nil }
    s.close
  end

  def test_counters
    s = authorized_session
    before = s.read_counter(0)
    assert_equal before + 1, s.increment_counter(0)
    assert_equal before + 1, s.read_counter(0)
    assert_equal 0, s.read_counter(1)
    assert_status(K::Error, K::Status::RANGE) { s.read_counter(7) }
    assert_status(K::Error, K::Status::RANGE) { s.increment_counter(7) }
    s.close
  end

  def test_app_crypto
    @dongle.session do |s|
      secret = Array.new(100) { |k| ((3 * k) + 7) % 256 }.pack('C*')
      K::Scope::ALL.each do |scope|
        blob = s.app_encrypt(scope, secret)
        assert_operator blob.bytesize, :>, secret.bytesize, "sealed data is longer, scope #{scope}"
        assert_equal scope, blob.getbyte(0), "scope byte, scope #{scope}"
        assert_equal secret, s.app_decrypt(blob)
        tampered = blob.dup
        tampered.setbyte(-1, tampered.getbyte(-1) ^ 1)
        assert_status(K::Error, K::Status::TAG_MISMATCH) { s.app_decrypt(tampered) }
      end
      assert_raises(ArgumentError) { s.app_encrypt(7, secret) }
      assert_equal '', s.app_decrypt(s.app_encrypt(K::Scope::DEVICE, ''))
      assert_status(K::Error, K::Status::INVALID_ARGUMENT) { s.app_decrypt("\x00\x01".b) }
    end
  end

  def test_rotation
    @dongle.session do |s|
      assert_status(K::WriteAuthorizationRequiredError, K::Status::AUTH_REQUIRED) do
        s.rotate_write_key(REPLACEMENT_KEY)
      end
      s.authorize_write(FACTORY_KEY)
      s.rotate_write_key(REPLACEMENT_KEY)
      s.write_record('lic', 'still-writable')
    end
    assert @dongle.info[:writeauth_rotated], 'rotated flag'
    @dongle.session do |s|
      assert_status(K::NotGenuineError, K::Status::NOT_GENUINE) { s.authorize_write(FACTORY_KEY) }
      s.authorize_write(REPLACEMENT_KEY)
      s.write_record('lic', 'new-key-writes')
      assert_equal 'new-key-writes'.b, s.read_record('lic')
    end
  end

  def test_scoped_helpers
    kept_ctx = nil
    kept_session = nil
    serial = K::Context.open do |ctx|
      kept_ctx = ctx
      dongle = ctx.open
      # list_records needs a session, so an answer proves the block form opened one.
      dongle.session do |s|
        kept_session = s
        assert_empty s.list_records
      end
      dongle.serial
    ensure
      dongle&.close
    end
    assert_equal SERIAL, serial
    assert kept_session.closed?
    assert kept_ctx.closed?
    assert_status(K::Error, K::Status::INVALID_ARGUMENT) { kept_ctx.enumerate }
  end

  def test_adopt
    out = K::Native.out_pointer
    open = Fiddle::Function.new(K::Native::LIB['licd_open'], [Fiddle::TYPE_VOIDP] * 3, Fiddle::TYPE_INT)
    assert_equal 0, open.call(@ctx.handle, nil, out)
    adopted = @ctx.adopt(out.ptr)
    assert_equal SERIAL, adopted.serial
    adopted.close
  end

  def test_close
    session = @dongle.session
    @dongle.close
    @dongle.close # idempotent
    assert @dongle.closed?
    assert_status(K::Error, K::Status::INVALID_ARGUMENT) { @dongle.serial }
    # A session whose dongle was closed refuses, and closing it does not touch the device.
    assert_status(K::Error, K::Status::INVALID_ARGUMENT) { session.list_records }
    session.close
    @ctx.close
    @ctx.close # idempotent
    assert @ctx.closed?
    assert_status(K::Error, K::Status::INVALID_ARGUMENT) { @ctx.enumerate }
  end
end
