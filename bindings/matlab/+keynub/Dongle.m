classdef Dongle < handle
%KEYNUB.DONGLE An open connection to a KeyNub license dongle.
%
%   Obtained from keynub.Context.open. Plaintext operations live here; anything
%   touching stored data needs an encrypted session (openSession).
%
%   See also keynub.Context, keynub.Session.

    properties (SetAccess = private)
        Context % the keynub.Context that opened this dongle
    end

    properties (Access = private)
        Handle = uint64(0);
    end

    methods
        function obj = Dongle(context, nativeHandle)
            % Called by keynub.Context.open, not directly.
            obj.Context = context;
            obj.Handle = nativeHandle;
        end

        function delete(obj)
            try
                obj.close();
            catch
                % See keynub.Context.delete: destructors must not throw.
            end
        end

        function close(obj)
            if obj.Handle ~= 0
                h = obj.Handle;
                obj.Handle = uint64(0);
                keynub.internal.call('close', h);
            end
        end

        function tf = isOpen(obj)
            tf = obj.Handle ~= 0;
        end

        function info = getInfo(obj)
            %GETINFO Plaintext device info, as a struct.
            %   protocolVersion  [major minor]
            %   firmwareVersion  [major minor patch]
            %   seReady       secure element responded
            %   provisioned      factory provisioning complete
            %   dataCapacity     bytes
            %   dataFree         bytes
            %   watchdogReboot   the dongle's PREVIOUS boot ended in a watchdog
            %                    timeout, i.e. the firmware hung and reset itself.
            %                    Worth logging: it is the only trace a field hang
            %                    leaves behind, and a power cycle clears it.
            %   isolated         the dongle confirmed at boot that its USB and
            %                    parsing code is fenced off from keys and
            %                    storage. The simulator reports false.
            info = keynub.internal.call('get_info', obj.checkedHandle());
        end

        function serial = getSerial(obj)
            %GETSERIAL The dongle serial as hex, e.g. '0123456789ABCDEFEE'.
            serial = keynub.internal.call('get_serial', obj.checkedHandle());
        end

        function result = verifyGenuine(obj)
            %VERIFYGENUINE Proves authenticity; errors if the dongle is not genuine.
            %   Validates the device certificate chain to the trusted root and
            %   checks a live ECDSA challenge-response, then returns a struct with
            %   genuine, serial, batch and provisionedDate from the certificate.
            result = keynub.internal.call('verify_genuine', obj.checkedHandle());
        end

        function [tf, identifier] = isGenuine(obj)
            %ISGENUINE Non-throwing form of VERIFYGENUINE for a licence gate.
            %   Fails closed: every failure — no dongle, I/O error, invalid
            %   certificate — reports false. IDENTIFIER returns the underlying
            %   MATLAB error identifier ('' on success) when you need to tell a
            %   missing dongle from a rejected one.
            tf = false;
            identifier = '';
            try
                result = obj.verifyGenuine();
                tf = result.genuine;
            catch err
                identifier = err.identifier;
            end
        end

        function session = openSession(obj)
            %OPENSESSION Opens an encrypted session (ECDH / HKDF / AES-256-GCM).
            keynub.internal.call('session_open', obj.checkedHandle());
            session = keynub.Session(obj);
        end
    end

    methods (Hidden)
        function h = checkedHandle(obj)
            if obj.Handle == 0
                error('KeyNub:licdongle:closed', 'the dongle has been closed');
            end
            h = obj.Handle;
        end
    end
end
