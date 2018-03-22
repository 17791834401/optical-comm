function eyediagram(x, n)
%% Simple eye-diagram plot. Matlab communications toolbox offers more sophisticated options
N = length(x);
M = floor(N/n);
sel = 1:M*n;

x = reshape(x(sel), n, M);
plot(1:n, x)

a = axis;
axis([1 n a(3) a(4)])