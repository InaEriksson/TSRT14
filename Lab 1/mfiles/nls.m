function [mhat,res] = nls(m,z,varargin)

%NLS solves nonlinear least-squares problems
%  [mhat,res] = nls(m,z,Property1,Value1,...)
%
%  The solution is defined as the minimizing argument th of
%  the non-linear least squares criterion.
%  Cases:
%  1. z=[] and m is a struct: Pure optimization problem.
%  2. z is a SIG object, m is a static model as an NL object: curve fitting
%  3. z is a SIG object, m is an NL object: NL model calibration
%
%  z may be a cell of SIG objects for multiple data sets
%  with different sampling rates and time intervals
%
%  1. Optimization: The solution is given by
%          thhat = arg min h(th)'*h(th)
%     a) m=h is an inline function with th as parameter vector (initialized with 0)
%     b) m is a struct with m.h as an inline function and
%        m.th as optional initial values of th.
%        m.J is optional inline object for gradient dh/dth
%  2. Curve fitting: h defines a parametric curve, and the solution is
%          thhat = arg min (y(t)-h(t,th))'*inv(R(x(t),th))*(y-h(t,th))
%     m is an NL object without dynamics (ex: m=nl([],h,[0,nu,ny,nth]); )
%     z is a SIG object sig(y,t)
%
%  3. NL object calibration/System identification
%     The non-linear (weighted) least squares criterion is minimized
%        thhat = arg min Sum_k
%                (y(t)-yhat(t))'*inv(R(x(t),th))*(y(t)-yhat(t))
%     where yhat(t) and x(t) are generated by the ordinary differential equation
%        xdot(t) = f(t,x(t),u(t);th)
%        yhat(t) = h(t,x(t),u(t);th)
%     For a Gaussian measurement error, LS coincides with maximum likelihood
%     This model defines the nominal dynamical system
%            x(t) = daspk(m.f,z.t,m.x0,[],m.u,m.th)
%            y(t) = feval(m.h,t,x(t),u(t),m.th)
%     By default, both x0 and th are calibrated using the data in z
%
%  Output structure
%   res.TH    The parameter value estimate at each iteration
%   res.V     Value of the cost function at each iteration
%   res.dV    The gradient at each iteration
%   res.sl    The step size at each iteration
%   res.m     The estimated model at each iteration as a cell
%   res.sol   The obtained solution (thetahat)
%   res.sol   The obtained solution (thetahat)
%   res.term  Text string with cause of termination
%   res.P     Covariance (estimated) for the parameters
%   res.Rhat  Covariance (estimated) for the measurements
%
%  Input arguments:
%
%   Property   Value{default}   Description
%   thmask     {ones(1,nth)}    Binary search mask for parameter vector
%   x0mask     {ones(1,nx)}     Binary search mask for initial state vector
%   x0         Cell array       In case z is a cell with multiple data sets,
%                               different known initial conditions can be set.
%                               x0{i} is the initial state for z{i}
%   alg                         Optimization algorithm
%               {'gn'}          Gauss-Newton
%               'rgn'           robust Gauss-Newton
%               'lm'            Levenberg-Marquardt
%               'sd'            steepest-descent
%   Rest      {0}|1             Estimate R based on minimal cost
%   disp      {0}|1             Display status of the iterations
%   maxiter   {50}              Maximum number of iterations in search direction
%   maxhalf   {50}              Maximum number of iterations in the line search.
%   gtol      {1e-4}            Tolerance for the gradient.
%   ctol      {1e-4}            Minimum relative decrease in the cost function
%                               before the search is terminated.
%   svtol     {1e-4}            Lower bound for the singular values of the
%                               Jacobian in robust Gauss-Newton
%   numgrad   (0)|1             force a numerical computation of the gradient
%                               even if a gradient m.J is specified
%
% Examples:
%    Optimization: Solve a quadratic problem
%    m.h=inline('[th(1)-1; 2*th(2)+2*th(2)-4]','th');
%    m.J=inline('[1 0;0 2]','th');
%    res=nls(m);   % Gradient J specified, symbolic derivative
%    th0=res.th
%    res=nls(m.h); % No gradient J specified, numeric derivative
%    th0=res.th
%
%    Curve fitting: exponential decrease
%    m.h=inline('th(1)*(1-exp(-th(2)*t))','t','th');  % Curve model
%    m.th=[2;0.5];                                    % True parameters
%    z.t=(0:1:3)';                                    % Time vector
%    z.y=m.h(z.t,m.th)                                % Measurements
%    m.th=m.th+0.3*randn(2,1);                        % Perturbed initial values
%    [mhat,res]=nls(m,z)                             % Calibrated curve
%
%

% Copyright (C) 2006 Thomas Sch�n and Fredrik Gustafsson
%$ Revision: 28-Oct-2019 $


if nargin<1
   error('NLS: The model m has to be specified')
end;

if nargin<2
   z=[];
end


% Optional parameters
opt=struct('alg','rgn','thmask',[],'x0mask',[],'x0',[],'disp',0,'maxiter',50,'svtol',1e-4,'maxhalf',50,'gtol',1e-4,'ctol',1e-4,'numgrad',0,'lmtau',1e-3,'Rest',0);
opt=optset(opt,varargin);

% Check m
if isa(m,'nl')
    % OK NL object
elseif isa(m,'nlrel')
    % OK NLREL object
elseif isa(m,'inline') || isa(m, 'function_handle')
    mstr=m;
    clear m
    m.h=mstr;
elseif isstr(m)
    m.h=inline(m);
elseif isstr(m.h)
    m.h=inline(m.h);
elseif isa(m.h,'inline') || isa(m.h, 'function_handle')
    % OK
else
    error('NLS: model definition is not recognized')
end

% Check z
if isempty(z)
   yvec=[];
elseif isstruct(z)
   if isfield(z,'y') & ~isempty(z.y)
      yvec=z.y;
   else
      error('NLS: z must have a non-zero field y')
   end
   if isfield(z,'t') & ~isempty(z.t)
      tvec=z.t;
   else
      error('NLS: z must have a non-zero field t')
   end
   if length(tvec)~=length(yvec)
%      error('NLS: z must have fields y and t of the same length')
   end
elseif isa(z,'sig')
   yvec=z.y;
   tvec=z.t;
elseif iscell(z)
   for kk=1:length(z)
      if ~isa(z{kk},'sig')
         error('NLS: z as an array must consists of SIG objects')
      end
   end
   yvec=z{1}.y;
   tvec=z{1}.t;
   if ~isempty(opt.x0) & length(opt.x0)~=length(z)
      error('NLS: x0 as a cell must have the same size as the cell array z')
   end
else
   error('NLS: unrecognized format of z')
end


% Validate m.f, m.h, m.th and m.x0
if ~isa(m,'nl') & isempty(z)
   % NLS cases 1
   nlscase=1;
   nx=0;
   nmax=10;
   if ~isfield(m,'th') | isempty(m.th);
      for i=1:nmax
         try
            htmp=feval(m.h,zeros(i,1));
            nth=i;
            m.th=zeros(nth,1);
            break
         end
      end
      if i==nmax
         error(['NLS case 1: m.h(th) gives an error for th=zeros(nth,1) where nth<= 10'])
      end
   else
      try
         htmp=feval(m.h,m.th);
         nth=length(m.th);
      catch
         error(['NLS case 1: m.h(m.th) gives an error'])
      end
   end
   theta=m.th;   % Starting point for the search
   ny=length(htmp);
   z.y=zeros(ny,1);
   z.t=[];
   m.nn=[0 0 ny nth];
elseif ~isa(m,'nl') & ~isempty(z)
   % NLS cases 2
   nlscase=2;
   nx=0;
   nmax=10;
   if ~isfield(m,'th') | isempty(m.th);
      for i=1:nmax
         try
            htmp=feval(m.h,tvec,zeros(i,1));
            nth=i;
            m.th=zeros(nth,1);
            break
         end
      end
      if i==nmax
         error(['NLS case 2: m.h(z.t,th) gives an error for th=zeros(nx,1) where nx<= 10'])
      end
   else
      try
         htmp=feval(m.h,tvec,m.th);
         nth=length(m.th);
      catch
         error(['NLS case 2: m.h(z.t,m.th) gives an error'])
      end
   end
   theta=m.th;   % Starting point for the search
   if length(yvec)~=length(htmp);
      error(['NLS case 2: m.h(z.t,m.th) must have the same size as z.y'])
   end
   m.nn=[0 0 length(htmp) length(theta)];
elseif isa(m,'nl')
   % NLS case 3
   nlscase=3;
   nx=m.nn(1);
   nu=m.nn(2);
   ny=m.nn(3);
   nth=m.nn(4);
   N=size(yvec,1);
   theta=m.th;   % Starting point for the search
   x0=m.x0;
end

% Check optional arguments again

if length(opt.thmask)==0
   opt.thmask=ones(1,nth);
elseif length(opt.thmask)~=nth
   error('NLS: length of thmask must equal nth=m.nn(4)'),
end
if length(opt.x0mask)==0
   opt.x0mask=ones(1,nx);
elseif length(opt.x0mask)~=nx
   error('NLS: length of x0mask must equal nx=m.nn(1)'),
end

if nlscase<3
    eta=theta;
    costfcn='staticcost';
elseif nlscase==3
    eta=[theta(find(opt.thmask));x0(find(opt.x0mask))];
    costfcn='nlcost';
elseif nlscase==4
    eta=[theta(find(opt.thmask));x0(find(opt.x0mask))];
    costfcn='nlcost';
end

switch opt.alg,
    case 'lm'              % Levenberg-Marquardt
	[res,mhat]=lm(m,z,eta,opt,costfcn,nlscase);
    otherwise	             % Line search methods
	[res,mhat]=lsmethods(m,z,eta,opt,costfcn,nlscase);
end;


%======================================================================
%                     OPTIMIZATION ALGORITHMS
%======================================================================
function [res,mhat]=lm(m,z,eta,opt,costfcn,nlscase)
% Levenberg-Marquardt, ONLY FOR STATIC MODELS THIS FAR!!!!!

iter=0;            % Counter for the number of iterations
theta=eta;         % Starting point for the search
res.TH(:,iter+1)=theta;    % Store the iterate
m.th=theta;
eps1=opt.gtol;
eps2=opt.ctol;
tau=opt.lmtau;   % 10^(-3) if the initial guess is close to the starting point.
nu=2;
%Compute cost, prediction error, Jacobian and gradient
[cost,epsilon,J]=feval(costfcn,m,z,zeros(size(eta)),opt.thmask,opt.x0mask,opt.x0);
grad=J*epsilon;
costinit=cost;
mu=tau*max(diag(J*J'));
found=(norm(grad,inf)<=eps1);
% Enter main loop
while and(~found,iter<opt.maxiter),
  iter=iter+1;
%  plm2=-(J*J'+mu*eye(length(theta)))\grad;       % Nonrobust computation of the search direction
  [U,S,V]=svd([J';sqrt(mu)*eye(length(theta))]);
  sv=diag(S);
  indmax=max(find(sv>opt.svtol));   % Find the last eigenvector to be used
  sv=sv(1:indmax);
  plm=zeros(size(theta));
  for i=1:indmax              % robustification
    plm=plm-(U(:,i)'*[epsilon;zeros(length(theta),1)]/sv(i))*V(:,i);
  end;
  if norm(plm) <= eps2*(norm(theta)+eps2)
    found=true;
  else
    thetanew=theta+plm;
    costold=feval(costfcn,m,z,zeros(size(eta)),opt.thmask,opt.x0mask,opt.x0);
    costnew=feval(costfcn,m,z,plm,opt.thmask,opt.x0mask,opt.x0);
    ro=(costold-costnew)/(0.5*plm'*(mu*plm-grad));
    if ro>0          % cost decreased!
      theta=thetanew;
      m.th=theta;
      [cost,epsilon,J]=feval(costfcn,m,z,zeros(size(eta)),opt.thmask,opt.x0mask,opt.x0);
      grad=J*epsilon;
      found=(norm(grad,inf)<=eps1);
      mu=mu*max(1/3,1-(2*ro-1)^3);
      nu=2;
    else            % cost increased!
      mu=mu*nu;
      nu=2*nu;
      cost=costold;
    end;
    % Store the result of the current iteration
    res.TH(:,iter+1)=theta;  % Store the iterate
    res.cost(iter)=cost;     % Store the cost
    res.grad(:,iter)=grad;   % Store the gradient
    res.normgrad(:,iter)=norm(grad);   % Store the norm of the gradient
    % Display result?
    if and((iter==1),opt.disp)
      divLine='-----------------------------------------------------';
      info=sprintf('%s%14s%14s%14s%6s','Iter','Cost','Grad. norm','mu','Alg');
      disp(divLine);    disp(info);    disp(divLine);
      info=sprintf('%5i%14.3e%14s%14s%6s',0,costinit,'-','-',opt.alg);
      disp(info);
      info=sprintf('%5i%14.3e%14.3e%14.3e%6s',iter,cost,norm(grad),mu,opt.alg);
      disp(info);
    end;
    if and((iter>1),opt.disp)
      info=sprintf('%5i%14.3e%14.3e%14.3e%6s',iter,cost,norm(grad),mu,opt.alg);
      disp(info);
    end;
  end;
end;
% DISPLAY THE REASON FOR TERMINATION
%======================================
if (iter==opt.maxiter)
  termtext='Terminated, opt.maxiter iterations has been performed.';
elseif norm(plm) <= eps2*(norm(theta)+eps2)
  termtext='Terminated, relative difference in the optimisation variable < opt.ctol.';
elseif (norm(grad,inf) <= eps1)
  termtext='Terminated, the norm of the gradient is smaller than opt.gtol.';
end
if opt.disp
	disp(termtext)
end;
res.term=termtext;
res.sol=theta;
mhat=m;





function [res,mhat]=lsmethods(m,z,eta,opt,costfcn,nlscase)
% Line search methods

nx=m.nn(1);
nu=m.nn(2);
ny=m.nn(3);
nth=m.nn(4);
%[N,ny]=size(z{1}.y);
m0=m;

termtext=[];
iter=0;
res.TH(:,iter+1)=eta;    % Store the iterate

while isempty(termtext)
    iter=iter+1;
    % 0. Initialize cost and Jacobian
    % ================================
    %Compute cost, prediction error, Jacobian and gradient
    [V0,epsilon,J]=feval(costfcn,m,z,zeros(size(eta)),opt.thmask,opt.x0mask,opt.x0);
    %Test if cost is sensible
    if (isinf(V0) | isnan(V0))
       error('NLS: Terminated due to infinite or NaN cost');
    end
    grad=J*epsilon;
    % 1. COMPUTE SEARCH DIRECTION:
    %================================
    switch opt.alg,
      case 'gn'
        % Gauss-Newton
        H=J*J';                   % Standard approximation of the Hessian
        p=-H\grad;
      case 'rgn'
        % Robust Gauss-Newton
        [U,S,V]=svd(J');
        sv=diag(S);
        indmax=max(find(sv>opt.svtol));   % Find the last eigenvector to be used
        if isempty(indmax)
            disp('Warning in NLS: Jacobian is zero')
            p=zeros(size(grad));
        else
            sv=sv(1:indmax);
            p=zeros(size(J,1),1);
            for i=1:indmax              % robustification
               p=p-(U(:,i)'*epsilon/sv(i))*V(:,i);
            end;
        end
      case 'sd'
        % Steepest-descent
        p=-grad;
    end;

    % 2. COMPUTE STEP LENGTH:
    %========================

    % Backtracking line search
    V=V0;
    alpha=1;      % Initial step length
    c1=1e-4;      % Slope for sufficient decrease
    rho=0.5;      % Contraction parameter
    Vnew=feval(costfcn,m,z,alpha*p,opt.thmask,opt.x0mask,opt.x0);
    j=1;
    while Vnew > V + c1*alpha*grad'*p & j<opt.maxhalf
        alpha=rho*alpha;
        Vnew=feval(costfcn,m,z,alpha*p,opt.thmask,opt.x0mask,opt.x0);
        j=j+1;
    end;
    % 3. UPDATE:
    %=============
    eta = eta + alpha*p;     % Update the iterate
    if nlscase==1
       m.th=eta;
    elseif nlscase<5
       m.th(find(opt.thmask))=eta(1:sum(opt.thmask));
       m.x0(find(opt.x0mask))=eta(sum(opt.thmask)+1:end);
       res.m{iter}=m;
    end
    res.sl(iter)=alpha;
    res.TH(:,iter+1)=eta;    % Store the iterate
    res.V(iter)=Vnew;        % Store the cost
    res.dV(:,iter)=grad;     % Store the gradient

    % Display result?
    if iter==1 & opt.disp
        divLine='-----------------------------------------------------';
        info=sprintf('%s%14s%14s%6s%6s','Iter','Cost','Grad. norm','BT','Alg');
        disp(divLine);    disp(info);    disp(divLine);
        info=sprintf('%5i%14.3e%14s%6s%6s',0,V0,'-','-',opt.alg);
        disp(info);
        info=sprintf('%5i%14.3e%14.3e%6i%6s',iter,Vnew,norm(grad),j,opt.alg);
        disp(info);
    end
    if iter>1 & opt.disp
        info=sprintf('%5i%14.3e%14.3e%6i%6s',iter,Vnew,norm(grad),j,opt.alg);
        disp(info);
    end

    % 4. CHECK IF THE SEARCH SHOULD BE TERMINATED:
    %=============================================
    if (iter==opt.maxiter)
        termtext='Maximum number of iterations opt.maxiter has been performed.';
     elseif Vnew > V
         termtext='Cost function increased.';
     elseif (V-Vnew < opt.ctol)
         termtext='Relative difference in the cost function < opt.ctol.';
    elseif (norm(grad) < opt.gtol)
        termtext='Norm of the gradient is smaller than opt.gtol.';
    end
end
if opt.disp
   disp(termtext)
end

% 5. Compute uncertainty estimates
% =================================
[V0,epsilon,J]=feval(costfcn,m,z,zeros(size(eta)),opt.thmask,opt.x0mask,opt.x0);
N=length(epsilon);
epsilon=reshape(epsilon,ny,N/ny);
if opt.Rest
   Rhat=eps*eye(ny)+epsilon*epsilon'/N; %(N/ny); changed 20130412
elseif ~isempty(m.pe)
   Rhat=cov(m.pe);
else
   Rhat=eye(ny);
end
Pinv=zeros(size(eta,1));
for j=1:N/ny
   Pinv=Pinv + J(:,j*ny-ny+1:j*ny)*pinv(Rhat)*J(:,j*ny-ny+1:j*ny)';
end
if nlscase==1
   ind=1:nth;
elseif nlscase<5
   P=zeros(nth+nx,nth+nx);
   I=zeros(nth+nx,nth+nx);
   ind=[find(opt.thmask(:));nth+find(opt.x0mask(:))];
end
P(ind,ind)=pinv(Pinv);
I(ind,ind)=Pinv;

% 6. Save the results
% ====================
res.term=termtext;
res.sol=eta;
res.V0=V0;
res.P=P;
res.Rhat=Rhat;
mhat=m;
mhat.I=I;
P=pinv(I(1:nth,1:nth));
P=(P+P')/2;
if ~isempty(P)
  ev=eig(P);
  P=P+max(ev)*1e-14*eye(nth);
end
mhat.P=P;
P0=pinv(I(nth+1:end,nth+1:end));
P0=(P0+P0')/2;
if ~isempty(P0)
   ev=eig(P0);
   P0=P0+max(ev)*1e-14*eye(size(P0));
end
mhat.px0=P0;
if opt.Rest
   mhat.pe=Rhat;
end


function [V,epsilon,J]=staticcost(m,z,p,thmask,x0mask,x0)
%Cost computation for static case
% z, thmask, x0mask, x0 not used here

if isempty(z.t)
    epsilon=feval(m.h,m.th+p)-z.y;
else
    epsilon=feval(m.h,z.t,m.th+p)-z.y;
end
if isa(m, 'nl') || isa(m, 'nlrel')  % Compensate for non-zero mean pe
  epsilon = bsxfun(@minus, epsilon, mean(m.pe).');
end

V=epsilon'*epsilon;

if nargout>1
    if isfield(m,'J') & ~isempty(m.J)    % Symbolic Jacobian computation
        if isempty(z.t)
            J=feval(m.J,m.th+p);
        else
            J=feval(m.J,z.t,m.th+p);
        end
    else
	mu=sqrt(eps);  % make adaptive later?
        nth=length(m.th);
        I=eye(nth);
        for k=1:nth
            if isempty(z.t)
                h1=feval(m.h,m.th+p+mu*I(:,k));
                h2=feval(m.h,m.th+p-mu*I(:,k));
            else
                h1=feval(m.h,z.t,m.th+p+mu*I(:,k));
                h2=feval(m.h,z.t,m.th+p-mu*I(:,k));
            end
            J(k,:)=(h1-h2)/2/mu;
        end;
    end;
end;


function [V,epsilon,JJ]=nlcost(m,z,p,thmask,x0mask,x0)
nx=m.nn(1);
nu=m.nn(2);
ny=m.nn(3);
nth=m.nn(4);
N=size(z,1);

mtmp=m;
if isa(mtmp,'nl')
   mtmp.pe=[]; % Simulate noise free measurements
end

if nargin==6
  n1=sum(thmask);
  n2=sum(x0mask);
  if nth>0
     mtmp.th(find(thmask))=m.th(find(thmask))+p(1:n1);
  end
  if nx>0
     mtmp.x0(find(x0mask))=m.x0(find(x0mask))+p(n1+1:n1+n2);
  end
elseif nargin==2
   % initial cost
else
   error('NLS.nlcost')
end

if isa(z,'sig')
   zz=z;
   clear z
   z{1}=zz;
end

epsilon=[];
JJ=[];
V=0;
%----Start loop in SIG objects-----------
for k=1:length(z);
   J=[];
   if  ~isempty(z{k}.u)
      zin=sig(z{k}.u,z{k}.t);
      zin.fs=z{k}.fs;
   else
      zin=z{k}.t;
   end
   if length(x0)>0
      mtmp.x0=x0{k};
   end
   ztmp=simulate(mtmp,zin);
   if (isa(m, 'nl') || isa(m, 'nlrel')) &&  ~isempty(m.pe)  % Compensate for non-zero mean pe
     ztmp.y = bsxfun(@plus, ztmp.y, mean(m.pe).');
   end

   epsilontmp=z{k}.y-ztmp.y;
   % vectorize (N,ny) matrix
   epsilontmp=epsilontmp';
   epsilontmp=epsilontmp(:);
   epsilon=[epsilon;epsilontmp];
   % cost
   V=V+epsilontmp'*epsilontmp;

   if nargout>2
        %Compute the gradients numerically
        % Basic equations
        % eta=[th(thmask);x0(x0mask)];
        % J=(dy/deta)' %'
        % J=(dh/dx)'(dx/deta) + dh/dth  %'
        % grad=dV/deta=psi*epsilon= (dh/deta + J) * epsilon
        %dxdth=numgrad(mtmp,ztmp,'dxdth',thmask);
        %dxdx0=numgrad(mtmp,ztmp,'dxdx0',x0mask);
        %dhdth=numgrad(mtmp,ztmp,'dhdth',thmask);
        %dhdx =numgrad(mtmp,ztmp,'dhdx');
        I=0.5*diag(thmask);
        i=0;
        for j=find(thmask(:)'==1);
            if length(j)==0; break; end
            i=i+1;
            h=1e-4*max([abs(mtmp.th(j)) 1e-4]);
            mm=mtmp;  % Temporary copy
            mm.th=mtmp.th+h*I(:,j);
            ztmp1=simulate(mm,zin);
            mm.th=mtmp.th-h*I(:,j);
            ztmp2=simulate(mm,zin);
            gradi=(ztmp1.y-ztmp2.y)/h;
            gradi=gradi';
            gradi=gradi(:);
            J(i,:)=gradi';
        end
        I=0.5*diag(x0mask);
        if nx>0
          for j=find(x0mask(:)'==1);
            if length(j)==0; break; end
            i=i+1;
            h=1e-4*max([abs(mtmp.x0(j)) 1e-4]);
            mm=mtmp;  % Temporary copy
            mm.x0=mtmp.x0+h*I(:,j);
            ztmp1=simulate(mm,zin);
            mm.x0=mtmp.x0-h*I(:,j);
            ztmp2=simulate(mm,zin);
            gradi=(ztmp1.y-ztmp2.y)/h;
            gradi=gradi';
            gradi=gradi(:);
            J(i,:)=gradi';
          end
        end
        J=-J;
        JJ=[JJ J];
   end
end
%----End loop in SIG objects-----------



% Obsolete
function [V,epsilon,J]=relcost(m,z,p,thmask,x0mask)

nx=m.nn(1);
nu=m.nn(2);
ny=m.nn(3);
nth=m.nn(4);

if isa(z,'sig')
   z{1}=z;
end

N=size(z,1);

mtmp=m;

if nargin==5
  n1=sum(thmask);
  n2=sum(x0mask);
  mtmp.th(find(thmask))=m.th(find(thmask))+p(1:n1);
  mtmp.x0(find(x0mask))=m.x0(find(x0mask))+p(n1+1:n1+n2);
elseif nargin==2
   % initial cost
else
   error('NLS.relcost')
end
ztmp=simulate(mtmp,z{k}.t);
if isa(m, 'nl') || isa(m, 'nlrel')  % Compensate for non-zero mean pe
  ztmp.y = bsxfun(@plus, ztmp.y, mean(m.pe).');
end
epsilon=z{k}.y-ztmp.y;
% vectorize (N,ny) matrix
epsilon=epsilon';
epsilon=epsilon(:);
% cost
V=epsilon'*epsilon;


if nargout>2
        % Compute the gradients numerically
        % dxdth, dxdx0, dhdth, dhdx
        % Basic equations
        % eta=[th(thmask);x0(x0mask)];
        % J=depsilon/dth=(dh/dx)'(dx/deta) + dh/dth  %'
        % grad=dV/deta=psi*epsilon= (dh/deta + J) * epsilon


        I=0.5*diag(thmask);
        i=0;
        for j=find(thmask(:)'==1);
            if length(j)==0; break; end
            i=i+1;
            h=1e-4*max([abs(mtmp.th(j)) 1e-4]);
            mm=mtmp;  % Temporary copy
            mm.th=mtmp.th+h*I(:,j);
            ztmp1=simulate(mm,z.t);
            mm.th=mtmp.th-h*I(:,j);
            ztmp2=simulate(mm,z.t);
            gradi=(ztmp1.y-ztmp2.y)/h;
            gradi=gradi';
            gradi=gradi(:);
            J(i,:)=gradi';
        end
        I=0.5*diag(x0mask);
        for j=find(x0mask(:)'==1);
            if length(j)==0; break; end
            i=i+1;
            h=1e-4*max([abs(mtmp.x0(j)) 1e-4]);
            mm=mtmp;  % Temporary copy
            mm.x0=mtmp.x0+h*I(:,j);
            ztmp1=simulate(mm,z.t);
            mm.x0=mtmp.x0-h*I(:,j);
            ztmp2=simulate(mm,z.t);
            gradi=(ztmp1.y-ztmp2.y)/h;
            gradi=gradi';
            gradi=gradi(:);
            J(i,:)=gradi';
        end
	J=-J;
end
