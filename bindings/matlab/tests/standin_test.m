function standin_test()
%STANDIN_TEST Every call of the MATLAB binding against a stand-in for the C ABI.
%   The MEX gateway compiled together with bindings/julia/test/stub/licd_stub.c,
%   one imaginary dongle held in memory, into one MEX file; no dongle and no
%   native library needed. Runs in MATLAB and in Octave. Errors when a check
%   fails.
%
%   Octave, from bindings/matlab (the stand-in's functions stay unexported, so
%   the MEX file exports mexFunction alone):
%
%       mkoctfile --mex -I../../include -o standin/licd_mex.mex src/licd_mex.c ../julia/test/stub/licd_stub.c
%       octave-cli --eval "addpath(pwd); addpath('standin'); addpath('tests'); standin_test"
%
%   MATLAB with Visual C++, from bindings/matlab:
%
%       >> mex -DLICD_BUILD_SHARED -I../../include -outdir standin src/licd_mex.c ../julia/test/stub/licd_stub.c
%       >> addpath(pwd); addpath('standin'); addpath('tests'); standin_test

serial = '04A1B2C3D4E5F6';
factoryKey = uint8([48 16 1 2 3]);        % 30 10 01 02 03
replacementKey = uint8([48 17 9 8 7 6]);  % 30 11 09 08 07 06
f = 0;

f = check(f, isequal(double(keynub.Context.libraryVersion()), [9 8 7]), 'library version');

ctx = keynub.Context();
d = ctx.enumerate();
f = check(f, numel(d) == 1 && strcmp(d(1).serial, serial) && strcmp(d(1).path, 'stub:0'), 'enumerate');
f = fails(f, 'noDevice', 'open by unknown serial', @() ctx.open('nope'));
f = fails(f, 'noDevice', 'open by unknown path', @() ctx.openPath('stub:9'));

dongle = ctx.open();
f = check(f, dongle.isOpen(), 'open');
f = check(f, strcmp(dongle.getSerial(), serial), 'serial');
info = dongle.getInfo();
f = check(f, isequal(double(info.protocolVersion), [1 0]), 'protocol version');
f = check(f, isequal(double(info.firmwareVersion), [2 3 4]), 'firmware version');
f = check(f, info.seReady && info.provisioned && info.isolated, 'flags set');
f = check(f, ~info.watchdogReboot && ~info.writeAuthRotated, 'flags clear');
f = check(f, info.dataCapacity == 1048576 && info.dataFree == 1000000, 'capacity');
g = dongle.verifyGenuine();
f = check(f, g.genuine && strcmp(g.serial, serial) && strcmp(g.provisionedDate, '2026-08-15'), 'genuine');
f = check(f, dongle.isGenuine(), 'isGenuine');

f = fails(f, 'certificateInvalid', 'malformed trust root', @() ctx.setTrustRoot(uint8([2 1 0])));
root = [uint8([48 130 1 0]), repmat(uint8(171), 1, 128)];   % 30 82 01 00, then AB...
ctx.setTrustRoot(root);
f = fails(f, 'certificateInvalid', 'verify against a foreign root', @() dongle.verifyGenuine());
[tf, identifier] = dongle.isGenuine();
f = check(f, ~tf && strcmp(identifier, 'KeyNub:licdongle:certificateInvalid'), 'isGenuine fails closed');
root(5:end) = 1;
ctx.setTrustRoot(root);
f = check(f, dongle.isGenuine(), 'isGenuine after the right root');

s = dongle.openSession();
f = check(f, s.isOpen(), 'session open');
payload = uint8('license-blob-0123456789');
f = fails(f, 'writeAuthorizationRequired', 'write before the write role', @() s.writeRecord('lic', payload));
f = fails(f, 'notGenuine', 'write role with a bad key', @() s.authorizeWrite(uint8([48 0])));
s.authorizeWrite(factoryKey);
s.writeRecord('lic', payload);
f = check(f, isequal(s.readRecord('lic'), payload(:)), 'read back');
s.writeRecord('cfg', uint8('cfgdata'));
recs = s.listRecords();
names = sort(arrayfun(@(r) r.name, recs, 'UniformOutput', false));
f = check(f, isequal(names(:)', {'cfg', 'lic'}), 'record names');
f = check(f, any(arrayfun(@(r) strcmp(r.name, 'lic') && r.size == numel(payload), recs)), 'record size');
f = fails(f, 'recordNotFound', 'read a missing record', @() s.readRecord('nope'));
f = fails(f, 'invalidArgument', 'erase with an empty name', @() s.eraseRecord(''));
s.eraseRecord('cfg');
f = check(f, numel(s.listRecords()) == 1, 'one record left');
s.writeRecord('empty', uint8([]));
f = check(f, isempty(s.readRecord('empty')), 'empty record');

before = double(s.readCounter(0));
f = check(f, double(s.incrementCounter(0)) == before + 1, 'increment');
f = check(f, double(s.readCounter(0)) == before + 1 && double(s.readCounter(1)) == 0, 'counters');
f = fails(f, 'range', 'counter out of range', @() s.readCounter(7));

secret = uint8(mod(3 * (0:99) + 7, 256));
% Scope as its numeric value (keynub.Scope.Device = 0, Developer = 1), which
% Octave's classdef also accepts.
for scope = [0 1]
    blob = s.appEncrypt(scope, secret);
    f = check(f, numel(blob) > numel(secret), 'sealed data is longer');
    f = check(f, double(blob(1)) == scope, 'scope byte');
    f = check(f, isequal(s.appDecrypt(blob), secret(:)), 'round trip');
    tampered = blob;
    tampered(end) = bitxor(tampered(end), uint8(1));
    f = fails(f, 'tagMismatch', 'tampered blob', @() s.appDecrypt(tampered));
end

s.eraseAllRecords();
f = check(f, isempty(s.listRecords()), 'erase all');

s.rotateWriteKey(replacementKey);
s.writeRecord('lic', uint8('still-writable'));
s.close();
f = check(f, ~s.isOpen(), 'session close');
f = check(f, dongle.getInfo().writeAuthRotated, 'rotated flag');
s = dongle.openSession();
f = fails(f, 'notGenuine', 'factory key after rotation', @() s.authorizeWrite(factoryKey));
s.authorizeWrite(replacementKey);
s.writeRecord('lic', uint8('new-key-writes'));
f = check(f, isequal(s.readRecord('lic'), uint8('new-key-writes')'), 'write with the new key');
s.close();

dongle.close();
f = check(f, ~dongle.isOpen(), 'closed');
ctx.close();

if f > 0
    error('KeyNub:licdongle:standinFailed', '%d check(s) failed', f);
end
fprintf('+keynub: every call passed against the ABI stand-in\n');
end

function f = check(f, condition, what)
if ~condition
    f = f + 1;
    fprintf('  FAIL  %s\n', what);
end
end

function f = fails(f, status, what, action)
try
    action();
    f = f + 1;
    fprintf('  FAIL  %s: no failure\n', what);
catch err
    if ~strcmp(err.identifier, ['KeyNub:licdongle:' status])
        f = f + 1;
        fprintf('  FAIL  %s: %s (%s)\n', what, err.message, err.identifier);
    end
end
end
