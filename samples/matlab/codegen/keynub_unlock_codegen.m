function [data, nbytes, status] = keynub_unlock_codegen(blob, maxBytes) %#codegen
%KEYNUB_UNLOCK_CODEGEN Dongle-gated data unlock that survives code generation.
%
%   [DATA, NBYTES, STATUS] = KEYNUB_UNLOCK_CODEGEN(BLOB, MAXBYTES) decrypts BLOB
%   (a uint8 vector produced by keynub.Session/appEncrypt) using an attached
%   KeyNub dongle. DATA is a MAXBYTES-by-1 uint8 buffer of which the first NBYTES
%   are valid; STATUS is 0 on success or a negative licd_status.
%
%   Usable from a MATLAB Function block and from MATLAB Coder, because it calls
%   the SDK's C ABI through keynub_gate.c rather than the MEX binding. The
%   generated code carries the licence check with it.
%
%   Generate with build_codegen_demo.m, which supplies the include paths and
%   libraries. In simulation (interpreted execution) the same file runs the MEX
%   binding instead, so a model behaves the same either way.
%
%   See also build_codegen_demo, keynub.Session/appEncrypt.

data = zeros(maxBytes, 1, 'uint8');
nbytes = uint32(0);
status = int32(0);

if coder.target('MATLAB')
    % Running interpreted (MATLAB, or a MATLAB Function block in simulation):
    % go through the binding, so behaviour matches the generated code.
    try
        ctx = keynub.Context();
        dongle = ctx.open();
        session = dongle.openSession();
        plain = session.appDecrypt(blob);
        if numel(plain) > maxBytes
            status = int32(-11); % LICD_E_RANGE
        else
            data(1:numel(plain)) = plain;
            nbytes = uint32(numel(plain));
        end
        session.close();
        delete(dongle);
        delete(ctx);
    catch
        % Fail closed with a generic status: the caller must treat any nonzero
        % status as "not licensed".
        status = int32(-7); % LICD_E_NOT_GENUINE
    end
else
    coder.cinclude('keynub_gate.h');
    status = int32(coder.ceval('keynub_unlock', coder.rref(blob), uint32(numel(blob)), ...
        coder.wref(data), uint32(maxBytes), coder.wref(nbytes)));
end
end
