function verify_and_read()
%VERIFY_AND_READ Minimal KeyNub dongle check from MATLAB.
%
%   Enumerate -> open -> verify genuine -> open a session -> read a record.
%   The MATLAB equivalent of samples/c/verify_and_read.
%
%   Run it with the binding folder on the path:
%       addpath('<SDK>/bindings/matlab');
%       verify_and_read
%
%   READ THIS FIRST: docs/integration-security.md. This sample prints a
%   result, which is the one thing a real licence check must NOT do — see
%   licence_protected_parameters.m for the shape that actually protects
%   something.

ctx = keynub.Context();

devices = ctx.enumerate();
fprintf('Found %d KeyNub dongle(s).\n', numel(devices));
for i = 1:numel(devices)
    fprintf('  [%d] serial %s (VID %04X PID %04X)\n', i, devices(i).serial, ...
        devices(i).vendorId, devices(i).productId);
end
if isempty(devices)
    fprintf('No dongle attached; nothing to do.\n');
    return
end

dongle = ctx.open(); % first dongle; pass a serial to pick a specific one

info = dongle.getInfo();
fprintf('Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n', ...
    info.protocolVersion(1), info.protocolVersion(2), ...
    info.firmwareVersion(1), info.firmwareVersion(2), info.firmwareVersion(3), ...
    info.dataFree, info.dataCapacity);
if info.watchdogReboot
    % The only trace a firmware hang leaves behind. Worth reporting to support.
    warning('KeyNub:watchdogReboot', ...
        'this dongle''s previous boot ended in a watchdog reset');
end

result = dongle.verifyGenuine();
fprintf('Genuine: %d (serial %s, provisioned %s)\n', ...
    result.genuine, result.serial, result.provisionedDate);

session = dongle.openSession();
records = session.listRecords();
fprintf('%d record(s) on the dongle:\n', numel(records));
for i = 1:numel(records)
    fprintf('  %-16s %6d bytes\n', records(i).name, records(i).size);
end
if ~isempty(records)
    data = session.readRecord(records(1).name);
    fprintf('First record (%s) is %d bytes.\n', records(1).name, numel(data));
end

session.close();
delete(dongle);
delete(ctx);
end
