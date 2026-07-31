classdef Session < handle
%KEYNUB.SESSION An encrypted session: records, counters and app-crypto.
%
%   Obtained from keynub.Dongle.openSession. Reads need a session; writes,
%   erases and counter increments additionally need the write role, granted by
%   authorizeWrite with the developer master key (vendor tooling only — never
%   ship that key in an application).
%
%   See also keynub.Dongle, keynub.Scope.

    properties (Access = private)
        Dongle
        Closed = false;
    end

    methods
        function obj = Session(dongle)
            % Called by keynub.Dongle.openSession, not directly.
            obj.Dongle = dongle;
        end

        function delete(obj)
            try
                obj.close();
            catch
                % See keynub.Context.delete: destructors must not throw.
            end
        end

        function close(obj)
            %CLOSE Ends the session, zeroizing the session keys on the dongle.
            if ~obj.Closed
                obj.Closed = true;
                keynub.internal.call('session_close', obj.Dongle.checkedHandle());
            end
        end

        function tf = isOpen(obj)
            tf = ~obj.Closed;
        end

        function authorizeWrite(obj, masterKeyDer)
            %AUTHORIZEWRITE Elevates to the write role with the developer master key.
            keynub.internal.call('write_auth', obj.checkedHandle(), masterKeyDer);
        end

        function records = listRecords(obj)
            %LISTRECORDS Struct array of stored records (name, size).
            records = keynub.internal.call('record_list', obj.checkedHandle());
        end

        function data = readRecord(obj, name, progress)
            %READRECORD Reads a record, returning a uint8 column vector.
            %   READRECORD(NAME, PROGRESS) reports progress through the function
            %   handle PROGRESS, called as PROGRESS(BYTESDONE, TOTALBYTES). If it
            %   returns false the transfer is cancelled and this raises
            %   KeyNub:licdongle:cancelled.
            if nargin < 3
                progress = [];
            end
            data = keynub.internal.call('record_read', obj.checkedHandle(), name, progress);
        end

        function writeRecord(obj, name, data, progress)
            %WRITERECORD Atomically replaces a record. Needs the write role.
            %   DATA may be uint8 (preferred), char, or whole numbers in 0..255.
            if nargin < 4
                progress = [];
            end
            keynub.internal.call('record_write', obj.checkedHandle(), name, data, progress);
        end

        function eraseRecord(obj, name)
            %ERASERECORD Erases one record. Needs the write role.
            if isempty(name)
                % Guarded because the gateway treats "no name" as erase-everything,
                % and an accidentally empty variable must not wipe the dongle.
                error('KeyNub:licdongle:invalidArgument', ...
                    'the record name must not be empty; use eraseAllRecords to erase everything');
            end
            keynub.internal.call('record_erase', obj.checkedHandle(), name);
        end

        function eraseAllRecords(obj)
            %ERASEALLRECORDS Erases every record. Needs the write role.
            keynub.internal.call('record_erase', obj.checkedHandle());
        end

        function value = readCounter(obj, counterId)
            %READCOUNTER Reads a hardware monotonic counter (0-based index).
            value = keynub.internal.call('counter_read', obj.checkedHandle(), counterId);
        end

        function value = incrementCounter(obj, counterId)
            %INCREMENTCOUNTER Increments a counter and returns the new value.
            %   Irreversible: the counter is monotonic in hardware. Needs the
            %   write role.
            value = keynub.internal.call('counter_increment', obj.checkedHandle(), counterId);
        end

        function blob = appEncrypt(obj, scope, plaintext)
            %APPENCRYPT Encrypts data so only a dongle of SCOPE can decrypt it.
            %   SCOPE is a keynub.Scope (Device or Developer). The bulk crypto
            %   stays on the host; only a small key is wrapped by the dongle.
            %
            %   This is the operation to build a licence check around: put
            %   something the program genuinely needs (a model parameter set,
            %   coefficients, a data file) through it, so removing the check
            %   removes the data too.
            blob = keynub.internal.call('app_encrypt', obj.checkedHandle(), ...
                double(scope), plaintext);
        end

        function data = appDecrypt(obj, blob)
            %APPDECRYPT Decrypts a blob produced by APPENCRYPT, using the dongle.
            data = keynub.internal.call('app_decrypt', obj.checkedHandle(), blob);
        end
    end

    methods (Hidden)
        function h = checkedHandle(obj)
            if obj.Closed
                error('KeyNub:licdongle:closed', 'the session has been closed');
            end
            h = obj.Dongle.checkedHandle();
        end
    end
end
