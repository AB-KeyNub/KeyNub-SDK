function licence_protected_parameters()
%LICENCE_PROTECTED_PARAMETERS The licence check shape that actually protects a toolbox.
%
%   The obvious MATLAB licence check looks like this:
%
%       if ~dongleIsPresent()      % <- one line to delete
%           error('no licence');
%       end
%       runMyToolbox();
%
%   Anyone with your .m files (or your P-coded files, or your compiled
%   executable) removes that line and the toolbox runs forever. The dongle proved
%   a genuine device was attached; it never protected anything.
%
%   Instead, put something the code genuinely needs *through* the dongle. Here
%   that is a set of plant coefficients: encrypted once when you issue the
%   licence, decrypted at run time. Delete the check and you have no
%   coefficients, so there is nothing left to run.
%
%   Good candidates in a MATLAB/Simulink product: identified plant parameters,
%   lookup tables and calibration maps, filter coefficients, a trained network's
%   weights, the reference data a validation suite compares against.
%
%   See docs/integration-security.md for the full argument.

ctx = keynub.Context();
dongle = ctx.open();
session = dongle.openSession();

% =========================================================================
% Step 1 - at licence-issue time, on YOUR machine (vendor side)
% =========================================================================
% Scope.Developer so that any dongle you have issued can decrypt it: you ship one
% encrypted file to every customer. Scope.Device would lock it to this one dongle,
% which is what you want for per-customer data.
coefficients = [0.9835 -1.2044 0.3311; 1.0 -0.7654 0.1234];
plaintext = typecast(coefficients(:), 'uint8');
blob = session.appEncrypt(keynub.Scope.Developer, plaintext);

protectedFile = fullfile(tempdir, 'plant_coefficients.keynub');
fid = fopen(protectedFile, 'wb');
fwrite(fid, blob, 'uint8');
fclose(fid);
fprintf('Wrote %d bytes of protected parameters to %s\n', numel(blob), protectedFile);

% =========================================================================
% Step 2 - at run time, on the CUSTOMER's machine
% =========================================================================
% This is the whole licence check. There is no boolean to patch out: without a
% genuine dongle appDecrypt fails, and without the coefficients the model cannot
% be built.
fid = fopen(protectedFile, 'rb');
stored = fread(fid, inf, '*uint8');
fclose(fid);

recovered = session.appDecrypt(stored);
restored = reshape(typecast(recovered, 'double'), size(coefficients));

fprintf('Recovered coefficients match: %d\n', isequal(restored, coefficients));

% A tampered file is rejected rather than yielding different numbers — the
% envelope is authenticated, so a customer cannot patch the parameters either.
tampered = stored;
tampered(end) = bitxor(tampered(end), uint8(1));
try
    session.appDecrypt(tampered);
    fprintf('UNEXPECTED: a tampered blob decrypted\n');
catch err
    fprintf('Tampered blob rejected (%s), as it must be.\n', err.identifier);
end

delete(protectedFile);
session.close();
delete(dongle);
delete(ctx);
end
