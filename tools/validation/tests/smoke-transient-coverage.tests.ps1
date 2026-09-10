param([switch]$NumericalOnly)

$ErrorActionPreference = 'Stop'

# CPU reference for footprint integration. This is not GPU/image validation.
Add-Type -TypeDefinition @'
using System;

public static class SmokeTransientCoverageTests
{
    public struct V
    {
        public double X, Y;
        public V(double x, double y) { X=x; Y=y; }
        public static V operator +(V a,V b) { return new V(a.X+b.X,a.Y+b.Y); }
        public static V operator -(V a,V b) { return new V(a.X-b.X,a.Y-b.Y); }
        public static V operator *(V a,double b) { return new V(a.X*b,a.Y*b); }
        public double Dot(V b) { return X*b.X+Y*b.Y; }
        public double Cross(V b) { return X*b.Y-Y*b.X; }
    }
    static int checks;
    static double Clamp(double x,double a,double b) { return Math.Max(a,Math.Min(b,x)); }
    static void Check(bool value,string name)
    { ++checks; if (!value) throw new Exception(name); }
    static void Near(double a,double b,double tolerance,string name)
    { Check(!Double.IsNaN(a) && !Double.IsInfinity(a) && Math.Abs(a-b)<=tolerance,
        name+": "+a+" versus "+b); }

    // Signed integral over the rectangle from the origin to (x,y).
    static double Quadrant(double x,double y,double r)
    {
        double sign=Math.Sign(x)*Math.Sign(y);
        x=Math.Min(Math.Abs(x),r); y=Math.Min(Math.Abs(y),r);
        if (x*x+y*y<=r*r) return sign*x*y;
        return sign*0.5*(y*Math.Sqrt(Math.Max(r*r-y*y,0))+
            x*Math.Sqrt(Math.Max(r*r-x*x,0))+r*r*(Math.Asin(x/r)+Math.Asin(y/r)-Math.PI/2));
    }
    static double DiskBox(double x0,double y0,double x1,double y1,double r)
    {
        if (r<=0) return 0;
        return Math.Max(0,Quadrant(x1,y1,r)-Quadrant(x0,y1,r)-
            Quadrant(x1,y0,r)+Quadrant(x0,y0,r));
    }
    static double EdgeArea(V a,V b,double r)
    {
        V d=b-a;
        double dd=d.Dot(d);
        if (dd<1e-20) return 0;
        double projection=-a.Dot(d)/dd;
        double discriminant=projection*projection-(a.Dot(a)-r*r)/dd;
        double half=Math.Sqrt(Math.Max(discriminant,0));
        double t1=discriminant>0 ? Clamp(projection-half,0,1) : 0;
        double t2=discriminant>0 ? Clamp(projection+half,0,1) : 0;
        double[] cuts={0,t1,t2,1};
        double result=0;
        for (int i=0;i<3;++i)
        {
            V p=a+d*cuts[i],q=a+d*cuts[i+1];
            V mid=(p+q)*0.5;
            result+=mid.Dot(mid)<=r*r ? p.Cross(q)*0.5 :
                r*r*Math.Atan2(p.Cross(q),p.Dot(q))*0.5;
        }
        return result;
    }
    static double DiskFootprint(V center,V halfX,V halfY,double radius)
    {
        if (radius<=0) return 0;
        V[] corners={center-halfX-halfY,center+halfX-halfY,
            center+halfX+halfY,center-halfX+halfY};
        double result=0;
        for (int i=0;i<4;++i) result+=EdgeArea(corners[i],corners[(i+1)&3],radius);
        return Clamp(Math.Abs(result),0,Math.Min(4*Math.Abs(halfX.Cross(halfY)),Math.PI*radius*radius));
    }
    static double Primitive(double q,double radial,double denominator)
    { return (radial*q-q*q*q/3)/denominator; }
    static double Integral(double impact,double r,double plateau,double near,double far)
    {
        double rr=r*r,bb=impact*impact;
        if (bb>=rr) return 0;
        double h=Math.Sqrt(rr-bb),q0=Math.Max(near,-h),q1=Math.Min(far,h);
        if (q1<=q0) return 0;
        double core2=rr*plateau*plateau,denominator=Math.Max(rr-core2,rr*0.0975);
        double radial=rr-bb;
        double shell=Primitive(q1,radial,denominator)-Primitive(q0,radial,denominator),core=0;
        if (bb<core2)
        {
            double ch=Math.Sqrt(core2-bb),a=Math.Max(q0,-ch),b=Math.Min(q1,ch);
            if (b>a) { core=b-a; shell-=Primitive(b,radial,denominator)-Primitive(a,radial,denominator); }
        }
        return core+Math.Max(shell,0);
    }
    static double Opacity(double tau)
    { return tau<1e-4 ? tau*(1-tau*(0.5-tau/6)) : 1-Math.Exp(-tau); }
    static double Tau(double opacity)
    { return opacity<1e-4 ? opacity*(1+opacity*(0.5+opacity/3)) : -Math.Log(Math.Max(1-opacity,1e-7)); }
    static readonly double[] Nodes={0.0694318442,0.3300094782,0.6699905218,0.9305681558};
    static readonly double[] Edges={0.1739274226,0.5,0.8260725774,1.0};
    static double Filter(V center,V hx,V hy,double radius,double plateau,double density,double near,double far)
    {
        double nearest=Clamp(0,near,far);
        if (far<=near || Math.Abs(nearest)>=radius) return 0;
        double support=Math.Sqrt(Math.Max(radius*radius-nearest*nearest,0));
        double priorArea=0,result=0;
        for (int i=0;i<4;++i)
        {
            double area=DiskFootprint(center,hx,hy,support*Math.Sqrt(Edges[i]));
            double tau=density*Integral(support*Math.Sqrt(Nodes[i]),radius,plateau,near,far);
            result+=Math.Max(area-priorArea,0)*Opacity(tau);
            priorArea=area;
        }
        return Clamp(result/Math.Max(4*Math.Abs(hx.Cross(hy)),1e-20),0,1);
    }
    static double OracleArea(double radius,double plateau,double density,double near,double far)
    {
        const int count=32768;
        double total=0;
        for (int i=0;i<count;++i)
            total+=Opacity(density*Integral(radius*Math.Sqrt((i+0.5)/count),radius,plateau,near,far));
        return Math.PI*radius*radius*total/count;
    }
    static double Scatter(double sigma,double distance)
    { return sigma*distance<1e-4 ? distance*(1-sigma*distance*(0.5-sigma*distance/6)) : Opacity(sigma*distance)/sigma; }
    static double NoiseWeight(double footprint,double occupied,double frequency)
    {
        double span=Math.Sqrt(footprint*footprint+occupied*occupied)*frequency;
        double blend=Clamp((span-0.5)/1.5,0,1);
        return 1-blend*blend*(3-2*blend);
    }
    static double NarrowWeight(double radius,double halfWidth)
    {
        double t=Clamp((radius/halfWidth-2)/2,0,1);
        return 1-t*t*(3-2*t);
    }
    // Production closure: shared cumulative narrow component, positive opacity
    // size crossfade, four resolved rays, then one mean-T record per depth slice.
    static double Production(double x,double y,double z,double r,double p,double density,int slices)
    {
        V hx=new V(0.5,0),hy=new V(0,0.5);
        double weight=NarrowWeight(r,0.5),transmittance=1;
        for (int slice=0;slice<slices;++slice)
        {
            double near=-3+6.0*slice/slices-z,far=-3+6.0*(slice+1)/slices-z;
            double nearAlpha=Filter(new V(x,y),hx,hy,r,p,density,-4-z,near);
            double farAlpha=Filter(new V(x,y),hx,hy,r,p,density,-4-z,far);
            double narrow=Math.Max(Tau(farAlpha)-Tau(nearAlpha),0);
            double meanOpacity=0;
            for (int lane=0;lane<4;++lane)
            {
                double dx=x+((lane&1)!=0 ? 0.25 : -0.25);
                double dy=y+((lane&2)!=0 ? 0.25 : -0.25);
                double exact=density*Integral(Math.Sqrt(dx*dx+dy*dy),r,p,near,far);
                double mixedOpacity=Opacity(exact)*(1-weight)+Opacity(narrow)*weight;
                meanOpacity+=mixedOpacity*0.25;
            }
            transmittance*=1-meanOpacity;
        }
        return 1-transmittance;
    }
    static double FootprintOracle(double x,double y,double r,double plateau,double density)
    {
        const int samples=512;
        double total=0;
        for (int row=0;row<samples;++row) for (int column=0;column<samples;++column)
        {
            double u=x+(column+0.5)/samples-0.5,v=y+(row+0.5)/samples-0.5;
            total+=Opacity(density*Integral(Math.Sqrt(u*u+v*v),r,plateau,-r,r));
        }
        return total/(samples*samples);
    }
    public static string Run()
    {
        V hx=new V(0.5,0),hy=new V(0,0.5);
        foreach (double r in new double[]{0.001,0.01,0.1,0.45,1,2})
        {
            Near(DiskFootprint(new V(0,0),new V(r,0),new V(0,r),r),Math.PI*r*r,1e-10,"full disk");
            Near(DiskBox(0,0,r,r,r),Math.PI*r*r/4,1e-10,"quarter disk");
            Near(DiskFootprint(new V(3*r,0),new V(r,0),new V(0,r),r),0,1e-10,"disjoint support");
        }
        // Circle/polygon implementation independently compared with a closed-form box integral.
        for (int i=0;i<47;++i)
        {
            double x=(i%7)*0.23-0.8,y=(i%11)*0.17-0.9,r=0.1+(i%5)*0.2;
            Near(DiskFootprint(new V(x,y),hx,hy,r),DiskBox(x-0.5,y-0.5,x+0.5,y+0.5,r),2e-8,"box oracle");
        }
        double maximumAreaError=0;
        foreach (double r in new double[]{0.005,0.04,0.15,0.45,1})
        foreach (double plateau in new double[]{0,0.6,0.95})
        foreach (double density in new double[]{0.001,1,10})
        {
            double first=-1,reference=OracleArea(r,plateau,density,-r,r);
            for (int shift=0;shift<=16;++shift)
            {
                double total=0;
                for (int y=-3;y<=3;++y) for (int x=-3;x<=3;++x)
                    total+=Filter(new V(x-shift/16.0,y-shift/23.0),hx,hy,r,plateau,density,-r,r);
                Check(total>0,"tiny plume never disappears between sample centers");
                if (first<0) first=total;
                Near(total,first,Math.Max(1e-11,first*2e-7),"fractional-cell projected area conservation");
            }
            double relative=Math.Abs(first-reference)/Math.Max(reference,1e-20);
            maximumAreaError=Math.Max(maximumAreaError,relative);
            Check(relative<0.04,"four-band full area agrees with high-sample oracle within4%");
        }
        // Skewed local-plane footprints cover the same plane without losing area.
        V skewX=new V(0.5,0),skewY=new V(0.25,0.4);
        double skewFirst=-1;
        for (int shift=0;shift<=16;++shift)
        {
            double total=0;
            for (int y=-3;y<=3;++y) for (int x=-3;x<=3;++x)
                total+=Filter(skewX*(2*x-shift/8.0)+skewY*(2*y-shift/11.0),
                    skewX,skewY,0.2,0.6,3,-0.2,0.2)*4*Math.Abs(skewX.Cross(skewY));
            if (skewFirst<0) skewFirst=total;
            Near(total,skewFirst,1e-8,"skew footprint partition");
        }
        // Fine positive lanes must average T and premultiplied source, never tau.
        foreach (double gridSigma in new double[]{0,0.001,0.5,4})
        foreach (double distance in new double[]{0.1,1,10})
        {
            double[] sigmas={0,4,0,4};
            double t=0,l=0;
            for (int lane=0;lane<4;++lane)
            {
                double sigma=gridSigma+sigmas[lane],source=gridSigma*0.7+sigmas[lane]*3;
                t+=Math.Exp(-sigma*distance)*0.25;
                l+=source*Scatter(sigma,distance)*0.25;
            }
            double effective=-Math.Log(t)/distance,sourceEffective=l/Scatter(effective,distance);
            Near(Math.Exp(-effective*distance),t,1e-12,"effective extinction preserves mean transmittance");
            Near(sourceEffective*Scatter(effective,distance),l,1e-12,"effective source preserves premultiplied radiance with grid");
            Check(effective+1e-12>=gridSigma,"grid medium is retained");
        }
        Near((1+Math.Exp(-4))*0.5,0.5091578194443671,1e-12,"half-empty/opaque case");
        Check(Math.Exp(-2)<(1+Math.Exp(-4))*0.5,"mean tau is spuriously denser");
        // Within-lane independent overlap is an explicit approximation: do not claim exact overlapping coverage.
        double a=0.1*Opacity(4),independent=1-(1-a)*(1-a),coincident=0.1*Opacity(8);
        Check(independent>coincident,"coincident sub-lane overlap closure limitation exposed");
        // Actual production-sized quadrature and size crossfade, not just the
        // standalone radial integral. Tiny coverage telescopes through slices.
        double maximumProductionAreaError=0;
        foreach (double r in new double[]{0.04,0.25,0.6,1,1.25,1.5,2})
        {
            double reference=OracleArea(r,0.6,4,-r,r),first=-1;
            for (int shift=0;shift<=16;++shift)
            {
                double area=0;
                for (int y=-4;y<=4;++y) for (int x=-4;x<=4;++x)
                    area+=Production(x-shift/16.0,y-shift/21.0,0,r,0.6,4,1);
                double relative=Math.Abs(area-reference)/reference;
                maximumProductionAreaError=Math.Max(maximumProductionAreaError,relative);
                Check(relative<0.07,"production size transition matches isolated reference area within7%");
                if (first<0) first=area;
                if (r<=1) Near(area,first,1e-8,"full narrow production area translation invariance");
            }
        }
        for (int move=0;move<=16;++move)
        foreach (int slices in new int[]{1,2,4,8,16})
        {
            double x=move/21.0-0.35,y=move/31.0-0.25,z=move/16.0-0.5;
            Near(Production(x,y,z,0.2,0.6,12,slices),
                Filter(new V(x,y),hx,hy,0.2,0.6,12,-1,1),1e-8,
                "production tiny-lobe optics preserve area through depth-slice motion");
        }
        for (int i=0;i<6;++i)
        {
            double x=0.1+i*0.1,y=0.07+i*0.06,r=0.25+i*0.08;
            Near(Filter(new V(x,y),hx,hy,r,0.6,4,-r,r),FootprintOracle(x,y,r,0.6,4),0.025,
                "partial footprint matches independent512x512 ray oracle");
        }
        // This known limitation is tested explicitly. Large-lobe lane coverage
        // correlation is not stored between depth slices in the existing ABI.
        double largeOne=Production(0.8,1.05,0.17,2,0.6,4,1);
        double largeSplit=Production(0.8,1.05,0.17,2,0.6,4,16);
        Check(Math.Abs(largeOne-largeSplit)>1e-6,"resolved cross-slice coverage closure limitation exposed");
        // A positive T/opacity crossfade must be exactly linear in coverage;
        // blending tau instead would create extra opacity in the size transition.
        for (int i=0;i<=20;++i)
        {
            double weight=i/20.0,expected=(1-weight)*Opacity(4)+weight*0.1;
            Near(Opacity(Tau(expected)),expected,1e-12,"positive optical size blend");
            Check(Opacity((1-weight)*4+weight*Tau(0.1))+1e-12>=expected,
                "tau blending would spuriously increase opacity");
        }
        // Cumulative-filter optical depth differences telescope across arbitrary depth splits.
        for (int shift=0;shift<=24;++shift)
        {
            double center=shift/48.0-0.25,prevTau=0,sumTau=0;
            for (int slice=0;slice<8;++slice)
            {
                double far=-0.5+(slice+1)/8.0-center;
                double opacity=Filter(new V(0.18,0.22),hx,hy,0.2,0.6,12,-1,far);
                double cumulative=Tau(opacity);
                Check(cumulative+1e-10>=prevTau,"cumulative prefix is monotone");
                sumTau+=Math.Max(cumulative-prevTau,0); prevTau=cumulative;
            }
            Near(Opacity(sumTau),Filter(new V(0.18,0.22),hx,hy,0.2,0.6,12,-1,1),2e-9,
                "isolated tiny puff area preserved across depth boundaries");
        }
        foreach (double tau in new double[]{1e-12,1e-9,1e-6,0.001,0.1,1,10})
            Near(Tau(Opacity(tau)),tau,Math.Max(1e-12,tau*1e-9),"near-zero optical-depth stability");
        double previousWeight=1;
        for (int i=0;i<=100;++i)
        {
            double weight=NoiseWeight(i*0.03,0,1);
            Check(weight<=previousWeight+1e-12 && weight>=0 && weight<=1,"noise filtering positive monotone");
            previousWeight=weight;
        }
        Near(NoiseWeight(0,0,1),1,0,"resolved noise retained");
        Near(NoiseWeight(0,3,1),0,0,"occupied chord filters unresolved depth noise");
        Near(0.5+(0.1-0.5)*NoiseWeight(3,0,1),0.5,0,"unresolved noise approaches mean");
        // Conservative fan/AABB rejection: each world-coordinate deviation is
        // affine in depth and bounded by the far-face absolute half axes.
        // Include skew/sign changes rather than checking only axis-aligned rays.
        for (int i=0;i<137;++i)
        {
            double far=1+i*0.17,depth=far*((i%17)/16.0);
            double x=(i%13)/6.0-1,y=(i%19)/9.0-1;
            double axisX=Math.Sin(i*0.71)*0.37,axisY=Math.Cos(i*0.43)*0.23;
            double padding=(Math.Abs(axisX)+Math.Abs(axisY))*far;
            double delta=(axisX*x+axisY*y)*depth;
            Check(Math.Abs(delta)<=padding+1e-12,"far-plane bound retains every sampled footprint ray");
        }
        return checks+" smoke coverage numeric checks passed; maximum four-band area error="+
            (maximumAreaError*100).ToString("F3")+"%; production size-transition area error="+
            (maximumProductionAreaError*100).ToString("F3")+"%. Independent narrow overlap and resolved cross-slice closure remain approximate.";
    }
}
'@

[SmokeTransientCoverageTests]::Run()

if ($NumericalOnly) { return }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$shaders = Join-Path $root 'source/common/rendering/nri/shaders'
$coverage = Get-Content -Raw (Join-Path $shaders 'Include/SmokeTransientCoverage.hlsli')
$lighting = Get-Content -Raw (Join-Path $shaders 'Include/SmokeTransientLighting.hlsli')
$materialize = Get-Content -Raw (Join-Path $shaders 'SmokeTransientMaterialize.cs.hlsl')
$resolve = Get-Content -Raw (Join-Path $shaders 'SmokeResolveVolume.cs.hlsl')
$bins = Get-Content -Raw (Join-Path $shaders 'SmokeTransientBuildBins.cs.hlsl')
function Require-Match([string]$text,[string]$pattern,[string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}
Require-Match $coverage 'SmokeTransientCoverageEdgeArea[\s\S]*atan2\(cross, product\)' 'Coverage must include exact circle/skew-footprint area support.'
Require-Match $coverage 'nodes\[4\][\s\S]*edges\[4\][\s\S]*band\s*<\s*4u' 'Narrow coverage must retain bounded four-band positive quadrature.'
Require-Match $coverage 'SmokeTransientCoverageTau\(farOpacity\)\s*-\s*SmokeTransientCoverageTau\(nearOpacity\)' 'Narrow coverage no longer uses cumulative optical-depth differences.'
Require-Match $coverage 'lerp\(SmokeTransientCoverageOpacity\(exactTau\),[\s\S]*SmokeTransientCoverageOpacity\(narrowTau\)' 'Size transition must blend opacity, not optical depth.'
Require-Match $coverage 'lower\s*-\s*padding,\s*upper\s*\+\s*padding' 'Coverage candidates can still be rejected by center-ray-only support.'
Require-Match $bins 'minimumColumn\s*-\s*1[\s\S]*maximumColumn\s*\+\s*1' 'Projected bins do not retain a conservative footprint guard.'
Require-Match $lighting 'lerp\(0\.5,\s*SmokeTransientBoundaryNoise[\s\S]*resolvedWeight' 'Unresolved noise must fade toward its mean.'
Require-Match $lighting 'position\s*=\s*gSmokeConstants\.CameraPosition\s*\+\s*unitRay\s*\*\s*\(\(entry\s*\+\s*exit\)\s*\*\s*0\.5\)' 'Resolved shell noise is not placed inside occupied support.'
Require-Match $materialize 'max\(previousMedium\.w,\s*0\.0\)\s*\+\s*laneExtinction\[lane\]' 'Area closure omits existing grid extinction.'
Require-Match $materialize 'max\(previousSource\.rgb,\s*0\.0\)\s*\+\s*laneSource\[lane\]' 'Area closure omits existing grid source radiance.'
Require-Match $materialize 'meanOpacity\s*\+=\s*SmokeTransientCoverageOpacity[\s\S]*meanRadiance\s*\+=' 'Optics must average opacity/T and premultiplied radiance.'
Require-Match $materialize 'combinedSource\s*=\s*meanRadiance\s*/' 'Materialization must write the positive joint effective source.'
Require-Match $materialize 'SmokeTransientCoverageReceiver\(lobe,\s*viewRay' 'Area-only contributions need a valid occupied local Fire receiver.'
Require-Match $resolve 'SmokeTransientCoverageEnabled\(\)\s*\?\s*saturate\(transmittance\)' 'Column resolve must retain T until spatial interpolation.'
Require-Match $resolve 'float4 volume\s*=\s*lerp[\s\S]*volume\.a\s*=\s*-log' 'Volume output must convert back to tau only after positive interpolation.'
if (($coverage + $materialize) -match 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible') {
    throw 'Spatial coverage filtering must not issue new scene-light rays.'
}
Write-Output 'Smoke coverage shader contracts passed.'

$renderer = Join-Path $root 'source/common/rendering/nri/renderer'
$cvars = Get-Content -Raw (Join-Path $renderer 'nri_cvars.cpp')
$cvarHeader = Get-Content -Raw (Join-Path $renderer 'nri_cvars.h')
$settings = Get-Content -Raw (Join-Path $renderer 'nri_renderer_settings.cpp')
$settingsHeader = Get-Content -Raw (Join-Path $renderer 'nri_renderer_settings.h')
$smoke = Get-Content -Raw (Join-Path $renderer 'nri_smoke.cpp')
$transient = Get-Content -Raw (Join-Path $renderer 'nri_smoke_transient_renderer.cpp')
$froxel = Get-Content -Raw (Join-Path $shaders 'Include/SmokeFroxel.hlsli')
$cmake = Get-Content -Raw (Join-Path $root 'source/CMakeLists.txt')
Require-Match $cvars 'CVAR\(Bool,\s*nri_ptsmoketransientcoverage,\s*true,\s*0\)' 'Coverage A/B must be default-on and session-only, without CVAR_ARCHIVE.'
Require-Match $cvarHeader 'EXTERN_CVAR\(Bool,\s*nri_ptsmoketransientcoverage\)' 'Coverage cvar is not exposed to settings.'
Require-Match $settingsHeader 'bool\s+transientCoverage\s*=\s*true;' 'Snapshot coverage default does not agree with the cvar.'
Require-Match $settings 'settings\.transientCoverage\s*=\s*nri_ptsmoketransientcoverage;' 'The coverage cvar does not reach renderer settings.'
Require-Match $froxel 'NRI_SMOKE_TRANSIENT_COVERAGE_FILTER\s+0x400u' 'CPU/shader coverage bit contract changed.'
Require-Match $smoke 'if\s*\(mSettings\.transientCoverage\)\s*constants\.lightSourceFlags\s*\|=\s*0x400u' 'Coverage bit must be a coherent global policy, not gated on transient group count.'
Require-Match $smoke 'NRISmokeConstants passConstants\s*=\s*constants;' 'Per-pass constants no longer inherit the shared coverage flag.'
if ($smoke -match 'lightSourceFlags\s*&=\s*~0x400u|lightSourceFlags\s*&\s*~0x400u') {
    throw 'A pass-specific override clears the coverage policy flag.'
}
$lightingKey = [regex]::Match($transient, 'const uint32_t lightingKey\s*=([^;]+);').Groups[1].Value
if (-not $lightingKey -or $lightingKey -match 'transientCoverage|0x400') {
    throw 'Spatial filtering must not invalidate or rebuild cached group lighting.'
}
Require-Match $cmake 'list\(FILTER NRI_SHARED_SHADER_FILES EXCLUDE REGEX "/SmokeTransientCoverage\[\.\]hlsli\$"\)' 'Coverage-only header changes should not rebuild unrelated TraceOpaque batches.'
Require-Match $cmake 'foreach\(_transient_pass Clear BuildBins LightBuild Materialize\)[\s\S]*DEPENDS[\s\S]*Include/SmokeTransientCoverage\.hlsli' 'Isolated transient shader rules omit the coverage helper dependency.'
Write-Output 'Smoke coverage CPU/A-B/build contracts passed.'
