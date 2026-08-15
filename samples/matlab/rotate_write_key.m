function status = rotate_write_key(currentKeyFile, newKeyFile)
%ROTATE_WRITE_KEY Take ownership of a new KeyNub dongle.
%
%   A dongle ships holding KeyNub's write-auth key. This replaces it with
%   yours, so that from the next session onward only your key can write
%   records, erase them or increment counters. Run it once per dongle, when
%   it arrives.
%
%   Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
%       openssl ecparam -name prime256v1 -genkey -noout | ...
%         openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
%
%   Run it with the binding folder on the path:
%       addpath('<SDK>/bindings/matlab');
%       rotate_write_key('../../keys/keynub-shipping-writeauth.key.der', 'my-key.der')
%
%   Targets real hardware: with no dongle attached it prints guidance and
%   returns 0.
%
%   The replacement key is worth what your licence-signing key is worth. It
%   cannot be recovered from the dongle, and a unit rotated to a key you have
%   lost has to come back to be re-provisioned.

current = readKey(currentKeyFile);
replacement = readKey(newKeyFile);

ctx = keynub.Context();
if isempty(ctx.enumerate())
    fprintf('Connect a KeyNub dongle and re-run.\n');
    status = 0;
    return
end

dongle = ctx.open(); % first dongle; pass a serial to pick a specific one
fprintf('dongle %s\n', dongle.getSerial());

session = dongle.openSession();
session.authorizeWrite(current);
session.rotateWriteKey(replacement);
fprintf('rotated: this dongle now answers only to your key\n');
session.close();

% A fresh session is the only place the change is observable: the session
% above keeps the role it was already granted.
session = dongle.openSession();
oldKeyStillWorks = true;
try
    session.authorizeWrite(current);
catch err
    if ~startsWith(err.identifier, 'KeyNub:licdongle:')
        rethrow(err);
    end
    oldKeyStillWorks = false;
end
if oldKeyStillWorks
    warning('KeyNub:sample:oldKeyStillWorks', ...
        'the old key still works -- do not ship this unit');
    status = 1;
    return
end
fprintf('confirmed: the old key no longer elevates\n');
session.authorizeWrite(replacement);
fprintf('confirmed: your key elevates\n');
session.close();

fprintf('\nKeep the replacement key safe. Every future write to this dongle needs it.\n');
status = 0;
end

function der = readKey(path)
%READKEY The DER file as a uint8 column vector, which is what the binding wants.
fid = fopen(path, 'rb');
if fid < 0
    error('KeyNub:sample:cannotOpen', 'cannot open %s', path);
end
cleanup = onCleanup(@() fclose(fid));
der = fread(fid, inf, '*uint8');
end
