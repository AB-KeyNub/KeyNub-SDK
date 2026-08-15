classdef Scope < uint8
%KEYNUB.SCOPE Who can decrypt data produced by keynub.Session.appEncrypt.
%
%   Device    - only this one physical dongle can decrypt it.
%   Developer - any dongle issued by the same developer can decrypt it, which
%               is what you want for data shipped to every customer.
%
%   See also keynub.Session/appEncrypt.

    enumeration
        Device    (0)
        Developer (1)
    end
end
