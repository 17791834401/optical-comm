classdef AnalogMixer < AnalogOperation % inherits properties and methods from class AnalogOperation
    properties
        Vamp = 1 % amplitude of input signal. This is used to adjust amount of distortion. 
        % If Vamp = 1 and input signal is in [-1, 1], there will be little
        % distortion
    end
    methods
        function obj = AnalogMixer(filt, N0, fs)
            %% Constructor
            obj@AnalogOperation(filt, N0, fs); % calls constructor of parent class Analog Operation
        end
        
        function varargout = copy(self)
            %% Deep copy of Mixer. Filters states aren't copied
            for k = 1:nargout
                varargout{k} = AnalogMixer(self.filt, self.N0, self.fs);
                varargout{k}.Vamp = self.Vamp;
            end
        end
        
        function yf = mix(self, x1, x2)
            %% Mixer function: mix signals and add noise. Inputs and output is filtered by filt.
            if self.ideal
                yf = self.ideal_mix(x1, x2);
                return
            end
            % Filter inputs
            [x1f, x2f] = self.filter_inputs(x1, x2);
            
            % Perform operation: mixing
            y = tanh(2*x1f/self.Vamp).*tanh(2*x2f/self.Vamp);
            % Note: factor of 2 adjust slope of tanh, so that there's a 1
            % to 1 relation between input and output, when clipping is
            % small
            
            % Add noise
            yn = self.add_noise(y);
            
            % Filter output
            yf = self.filter_output(yn);
        end
        
        function y = ideal_mix(~, x1, x2)
            %% Ideal mixer operation: no noise and no filtering
            y = x1.*x2;
        end
        
        function validate(self)
            %% Validate operation mix for the non-ideal case, where filtering is performed
            self.reset();
            N = 100;
            w = 2*pi*self.filt.fcnorm*self.fs/4;
            [~, t] = freq_time(N, self.fs);
            
            x1 = sin(w*t + pi*(2*rand(1)-1));
            x2 = sin(2*w*t + pi*(2*rand(1)-1));
            
            x1fref = filter(self.filt.num, self.filt.den, x1);
            x2fref = filter(self.filt.num, self.filt.den, x2);
            yref = self.ideal_mix(x1fref, x2fref);
            ynref = self.add_noise(yref);
            yfref = filter(self.filt.num, self.filt.den, ynref);
            
            y = zeros(1, N);
            for k = 1:N
                y(k) = self.mix(x1(k), x2(k));
            end
            
            figure, clf, hold on, box on
            plot(t, y)
            plot(t, yfref, '--')
            plot(t, self.ideal_mix(x1, x2), ':');
            legend('this class', 'reference', 'ideal')
            self.reset();
        end
    end
end