classdef LicenseCheck < matlab.System
%KEYNUB.LICENSECHECK Simulink licence gate backed by a KeyNub dongle.
%
%   Drop this into a model with a MATLAB System block (set the block's System
%   object name to keynub.LicenseCheck). It verifies a genuine dongle at model
%   initialisation, optionally re-checks while the simulation runs so pulling the
%   dongle is noticed, and outputs a logical "licensed" signal.
%
%   Properties:
%     Serial              dongle serial to require, or '' for the first found
%     RequireRecord       record name that must exist on the dongle, or '' for none
%     RecheckEverySteps   re-verify every N steps (0 = only at initialisation)
%     StopOnFailure       stop the simulation with an error instead of outputting
%                         false
%
%   This block runs in interpreted execution only, and deliberately cannot be
%   compiled into generated code: it calls a MEX gateway. To gate *generated*
%   code instead, call the C API from the generated build — see
%   samples/matlab/keynub_gate_codegen.m.
%
%   A caution worth more than the block itself: a boolean output is a licence
%   check an attacker deletes in an afternoon. Wire something the model actually
%   needs through keynub.Session/appDecrypt — plant coefficients, a lookup table,
%   a calibration set — so removing the dongle removes the data. See
%   docs/integration-security.md.
%
%   See also keynub.Context, keynub.Dongle.

    properties (Nontunable)
        Serial = '';            % required dongle serial ('' = first found)
        RequireRecord = '';     % record that must be present ('' = none)
        RecheckEverySteps = 0;  % 0 = verify at initialisation only
    end

    properties (Nontunable, Logical)
        StopOnFailure = true;   % error out rather than output false
    end

    properties (Access = private)
        Ctx
        Dev
        StepCount = 0;
        Licensed = false;
    end

    methods (Access = protected)
        function setupImpl(obj)
            obj.StepCount = 0;
            obj.Licensed = obj.verify();
        end

        function resetImpl(obj)
            obj.StepCount = 0;
        end

        function licensed = stepImpl(obj)
            if obj.RecheckEverySteps > 0
                obj.StepCount = obj.StepCount + 1;
                if mod(obj.StepCount, obj.RecheckEverySteps) == 0
                    obj.Licensed = obj.verify();
                end
            end
            licensed = obj.Licensed;
        end

        function releaseImpl(obj)
            % Release the dongle when the simulation ends, so the next run (or
            % another MATLAB session) can open it.
            obj.Dev = [];
            obj.Ctx = [];
        end

        % --- MATLAB System block plumbing -----------------------------------
        function num = getNumInputsImpl(~)
            num = 0;
        end

        function num = getNumOutputsImpl(~)
            num = 1;
        end

        function sz = getOutputSizeImpl(~)
            sz = [1 1];
        end

        function dt = getOutputDataTypeImpl(~)
            dt = 'logical';
        end

        function cp = isOutputComplexImpl(~)
            cp = false;
        end

        function fixed = isOutputFixedSizeImpl(~)
            fixed = true;
        end
    end

    methods (Static, Access = protected)
        function mode = getSimulateUsingImpl(~)
            % The gateway is a MEX file, so there is nothing to generate code
            % from. Pinning the mode gives a clear block dialog instead of a
            % confusing codegen failure.
            mode = 'Interpreted execution';
        end

        function show = showSimulateUsingImpl(~)
            show = false;
        end
    end

    methods (Access = private)
        function licensed = verify(obj)
            licensed = false;
            reason = '';
            try
                if isempty(obj.Ctx)
                    obj.Ctx = keynub.Context();
                    obj.Dev = obj.Ctx.open(obj.Serial);
                end
                result = obj.Dev.verifyGenuine();
                licensed = result.genuine;
                if licensed && ~isempty(obj.RequireRecord)
                    session = obj.Dev.openSession();
                    records = session.listRecords();
                    licensed = any(strcmp({records.name}, obj.RequireRecord));
                    if ~licensed
                        reason = sprintf('the dongle has no ''%s'' record', obj.RequireRecord);
                    end
                    session.close();
                end
            catch err
                % Fail closed, and drop the cached handles so the next check
                % re-opens: a dongle that was unplugged and plugged back in
                % should start working again without restarting the simulation.
                obj.Ctx = [];
                obj.Dev = [];
                licensed = false;
                reason = err.message;
            end
            if ~licensed && obj.StopOnFailure
                if isempty(reason)
                    reason = 'the attached dongle is not genuine';
                end
                error('KeyNub:licdongle:notLicensed', ...
                    'KeyNub licence check failed: %s', reason);
            end
        end
    end
end
