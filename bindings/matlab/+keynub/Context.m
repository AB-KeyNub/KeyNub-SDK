classdef Context < handle
%KEYNUB.CONTEXT Library context: enumerate and open KeyNub license dongles.
%
%   ctx = keynub.Context() creates a context. Close it with delete(ctx) or let
%   MATLAB clear it; the dongles it opened are closed with it.
%
%   Example:
%       ctx    = keynub.Context();
%       dongle = ctx.open();                 % first dongle found
%       result = dongle.verifyGenuine();
%
%   Before writing a licence check, read docs/integration-security.md. The
%   dongle proves a genuine device is attached; it cannot stop an attacker from
%   patching the MATLAB code that asks. Branching on a boolean is bypassed
%   trivially — feed something the program actually needs through
%   Session.appEncrypt/appDecrypt instead.
%
%   See also keynub.Dongle, keynub.Session, keynub.build.

    properties (Access = private)
        Handle = uint64(0);
    end

    methods
        function obj = Context()
            obj.Handle = keynub.internal.call('init');
        end

        function delete(obj)
            try
                obj.close();
            catch
                % A destructor must not throw: MATLAB clears the workspace in no
                % defined order, and a warning storm at `clear` would be the only
                % result. The gateway releases the handle either way.
            end
        end

        function close(obj)
            %CLOSE Releases the context and every dongle it opened.
            if obj.Handle ~= 0
                h = obj.Handle;
                obj.Handle = uint64(0); % first, so a failure cannot double-free
                keynub.internal.call('free', h);
            end
        end

        function tf = isOpen(obj)
            tf = obj.Handle ~= 0;
        end

        function devices = enumerate(obj)
            %ENUMERATE Struct array of connected dongles (serial, path, ids).
            %   Empty when none are attached — that is a normal result, not an error.
            devices = keynub.internal.call('enumerate', obj.checkedHandle());
        end

        function dongle = open(obj, serial)
            %OPEN Opens the dongle with this serial, or the first one found.
            if nargin < 2 || isempty(serial)
                serial = '';
            end
            dongle = keynub.Dongle(obj, ...
                keynub.internal.call('open', obj.checkedHandle(), serial));
        end

        function dongle = openPath(obj, path)
            %OPENPATH Opens a specific dongle by the path from ENUMERATE.
            dongle = keynub.Dongle(obj, ...
                keynub.internal.call('open_path', obj.checkedHandle(), path));
        end

        function setTrustRoot(obj, der)
            %SETTRUSTROOT Overrides the CA root verifyGenuine checks against.
            %   Applications do not need this: a release build embeds the KeyNub
            %   production root. It is for vendor tooling that verifies dongles
            %   issued under a different CA. DER is a uint8 vector.
            keynub.internal.call('set_trust_root', obj.checkedHandle(), der);
        end

        function detail = lastErrorDetail(obj)
            %LASTERRORDETAIL Diagnostic detail for the most recent failure.
            detail = keynub.internal.call('error_detail', obj.checkedHandle());
        end
    end

    methods (Hidden)
        function h = checkedHandle(obj)
            if obj.Handle == 0
                error('KeyNub:licdongle:closed', 'the context has been closed');
            end
            h = obj.Handle;
        end
    end

    methods (Static)
        function v = libraryVersion()
            %LIBRARYVERSION Native core version as [major minor patch].
            v = keynub.internal.call('version');
        end
    end
end
