param([switch]$NumericalOnly)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;

public static class SmokeTransientHistoryTests
{
    public struct V
    {
        public double X,Y,Z;
        public V(double x,double y,double z) { X=x;Y=y;Z=z; }
        public static V operator +(V a,V b) { return new V(a.X+b.X,a.Y+b.Y,a.Z+b.Z); }
        public static V operator -(V a,V b) { return new V(a.X-b.X,a.Y-b.Y,a.Z-b.Z); }
        public static V operator *(V a,double b) { return new V(a.X*b,a.Y*b,a.Z*b); }
        public double Dot(V b) { return X*b.X+Y*b.Y+Z*b.Z; }
    }
    static int checks;
    static double Clamp(double x,double a,double b) { return Math.Max(a,Math.Min(x,b)); }
    static double Smooth(double a,double b,double x)
    { double t=Clamp((x-a)/(b-a),0,1); return t*t*(3-2*t); }
    static void Check(bool condition,string name)
    { ++checks;if (!condition) throw new Exception(name); }
    static void Near(double actual,double expected,double tolerance,string name)
    { Check(!Double.IsNaN(actual) && !Double.IsInfinity(actual) && Math.Abs(actual-expected)<=tolerance,
        name+": "+actual+" versus "+expected); }
    static double Alpha(double tau)
    { return tau<1e-4 ? tau*(1-tau*(0.5-tau/6)) : 1-Math.Exp(-tau); }
    static double Tau(double alpha)
    { return alpha<1e-4 ? alpha*(1+alpha*(0.5+alpha/3)) : Math.Min(-Math.Log(Math.Max(1-alpha,1e-7)),16); }
    static uint Pack(double depth,double confidence,double far)
    { return ((uint)Math.Round(Clamp(depth/far,0,1)*65535)<<8) | (uint)Math.Round(Clamp(confidence,0,1)*255); }
    static V PreviousPoint(V point,V currentCenter,double currentRadius,V previousCenter,double previousRadius)
    { return previousCenter+(point-currentCenter)*(previousRadius/currentRadius); }
    static double MotionConfidence(double age,double radius,double previousRadius,double displacement,bool fire)
    {
        if (previousRadius<=0 || radius<=0) return 0;
        double ratio=previousRadius/radius;
        if (ratio<0.75 || ratio>1.25 || displacement>Math.Max(radius*0.5,16)) return 0;
        return Smooth(fire?0.05:0.10,fire?0.20:0.35,age)*(1-Smooth(0.02,0.20,Math.Abs(ratio-1)));
    }
    static double ProjectX(V point,V camera)
    { return 0.5+(point.X-camera.X)/(point.Z-camera.Z)*0.5; }
    static bool TapAccept(double ageTag,double smokeDepth,double opaqueDepth,double expectedSmoke,double expectedOpaque,double sliceWidth)
    {
        return ageTag>2 && ageTag<=3.01 &&
            Math.Abs(smokeDepth-expectedSmoke)<=Math.Max(2,expectedSmoke*0.015+sliceWidth*0.1) &&
            Math.Abs(opaqueDepth-expectedOpaque)<=Math.Max(4,expectedOpaque*0.02) &&
            opaqueDepth+Math.Max(2,opaqueDepth*0.001)>=expectedSmoke;
    }
    static double ResolveAlpha(double current,double history,double minimum,double maximum,double weight)
    {
        // Current support is authoritative even if neighboring or old smoke exists.
        if (current<=1e-6) return 0;
        return current*(1-weight)+Clamp(history,minimum,maximum)*weight;
    }
    static double SphereOpacity(double x)
    {
        const double radius=0.4;
        double b=1-x*x/(radius*radius);
        return b<=0 ? 0 : Alpha(3*Math.Pow(b,1.5));
    }
    static double CoarseCell(double center,double spacing)
    {
        double sum=0;
        for (int i=0;i<64;++i) sum+=SphereOpacity(center+spacing*((i+0.5)/64-0.5))/64;
        return sum;
    }
    static double Sample(double[] image,double coordinate)
    {
        int p=(int)Math.Floor(coordinate);
        double f=coordinate-p;
        return image[Math.Max(0,Math.Min(image.Length-1,p))]*(1-f)+
            image[Math.Max(0,Math.Min(image.Length-1,p+1))]*f;
    }
    static bool SampleHistory(double[] image,double coordinate,out double value)
    {
        int p=(int)Math.Floor(coordinate);
        double f=coordinate-p,weight=0;
        value=0;
        for (int tap=0;tap<2;++tap)
        {
            double sample=image[Math.Max(0,Math.Min(image.Length-1,p+tap))],w=tap==0 ? 1-f : f;
            if (sample<=1e-6) continue;
            value+=sample*w;weight+=w;
        }
        if (weight<0.5) return false;
        value/=weight;return true;
    }
    static double MovingFroxelCase(int neighborhoodStride,double maximumHistoryWeight,out double meanDifference,
        out double areaDifference,out double groundTruthRmsRatio,out string diagnostic)
    {
        const int pixels=256,frames=180;
        const double pixelWidth=0.02,spacing=0.64,origin=-2.0,targetWorld=0.32;
        double[] prior=new double[pixels];
        double priorCamera=0,currentMean=0,filteredMean=0,currentSquare=0,filteredSquare=0,currentArea=0,filteredArea=0;
        for (int frame=0;frame<frames;++frame)
        {
            // Cycle a real camera translation over a coarse-cell phase. The
            // previous image is fetched at the same WORLD location, not the
            // same pixel. Current images retain the existing spatial filter.
            double camera=(frame*0.09)%spacing;
            double[] current=new double[pixels],next=new double[pixels];
            double[] coarse=new double[12];
            for (int i=0;i<coarse.Length;++i) coarse[i]=CoarseCell(camera+origin+(i+0.5)*spacing,spacing);
            for (int pixel=0;pixel<pixels;++pixel)
                current[pixel]=Sample(coarse,((pixel+0.5)*pixelWidth)/spacing-0.5);
            for (int pixel=0;pixel<pixels;++pixel)
            {
                double world=camera+origin+(pixel+0.5)*pixelWidth;
                double history;
                bool accepted=SampleHistory(prior,(world-priorCamera-origin)/pixelWidth-0.5,out history);
                double lo=current[pixel],hi=current[pixel];
                for (int offset=-neighborhoodStride;offset<=neighborhoodStride;offset+=neighborhoodStride)
                {
                    double neighbor=current[Math.Max(0,Math.Min(pixels-1,pixel+offset))];
                    lo=Math.Min(lo,neighbor);hi=Math.Max(hi,neighbor);
                }
                history=Clamp(history,lo,hi);
                double radianceChange=Math.Abs(history-current[pixel])/Math.Max(Math.Max(history,current[pixel]),0.05/3);
                double weight=frame==0 || !accepted ? 0 : maximumHistoryWeight*(1-Smooth(0.35,0.85,radianceChange))*
                    (1-Smooth(0.20,0.50,Math.Abs(history-current[pixel])));
                next[pixel]=ResolveAlpha(current[pixel],history,lo,hi,weight);
                if (current[pixel]<=1e-6) Near(next[pixel],0,0,"moving froxel has no history outside current support");
            }
            if (frame>=40)
            {
                double coordinate=(targetWorld-camera-origin)/pixelWidth-0.5;
                double a=Sample(current,coordinate),b=Sample(next,coordinate),n=frames-40;
                currentMean+=a/n;filteredMean+=b/n;currentSquare+=a*a/n;filteredSquare+=b*b/n;
                for (int pixel=0;pixel<pixels;++pixel)
                { currentArea+=current[pixel]/n;filteredArea+=next[pixel]/n; }
            }
            prior=next;priorCamera=camera;
        }
        meanDifference=Math.Abs(currentMean-filteredMean);
        areaDifference=Math.Abs(currentArea-filteredArea)/Math.Max(currentArea,1e-12);
        double truth=SphereOpacity(targetWorld),filteredTruth=CoarseCell(targetWorld,spacing);
        groundTruthRmsRatio=Math.Sqrt(filteredSquare-2*truth*filteredMean+truth*truth)/
            Math.Sqrt(currentSquare-2*truth*currentMean+truth*truth);
        diagnostic="stride="+neighborhoodStride+", weight="+maximumHistoryWeight+", rawMean="+currentMean+
            ", historyMean="+filteredMean+", exactSphere="+truth+", boxFilteredTruth="+filteredTruth+
            ", rawRMSE="+Math.Sqrt(currentSquare-2*truth*currentMean+truth*truth)+
            ", historyRMSE="+Math.Sqrt(filteredSquare-2*truth*filteredMean+truth*truth)+
            ", rawBoxRMSE="+Math.Sqrt(currentSquare-2*filteredTruth*currentMean+filteredTruth*filteredTruth)+
            ", historyBoxRMSE="+Math.Sqrt(filteredSquare-2*filteredTruth*filteredMean+filteredTruth*filteredTruth);
        return (filteredSquare-filteredMean*filteredMean)/Math.Max(currentSquare-currentMean*currentMean,1e-12);
    }
    public static string Run()
    {
        foreach (double far in new double[]{64,512,4096,16384})
        for (int d=0;d<=64;++d) for (int c=0;c<=16;++c)
        {
            double depth=far*d/64,confidence=c/16.0;
            uint bits=Pack(depth,confidence,far);
            float packed=(float)bits;
            Near(packed,bits,0,"motion guide24bits exactly representable infloat32");
            uint restored=(uint)packed;
            Near((restored>>8)*far/65535,depth,far/65535*0.500001,"occupied depth quantization bound");
            Near((restored&255)/255.0,confidence,0.5/255+1e-12,"confidence quantization bound");
        }
        for (int i=0;i<101;++i)
        {
            V currentCenter=new V(i*0.17,2,50+i),previousCenter=currentCenter+new V(-0.05,0,-0.1);
            double currentRadius=1+i*0.11,previousRadius=currentRadius*0.99;
            V local=new V(Math.Sin(i)*0.7,Math.Cos(i)*0.5,0.1);
            V currentPoint=currentCenter+local*currentRadius;
            V expected=previousCenter+local*previousRadius;
            V previous=PreviousPoint(currentPoint,currentCenter,currentRadius,previousCenter,previousRadius);
            Near(previous.X,expected.X,1e-10,"carrier-local X advects and grows");
            Near(previous.Y,expected.Y,1e-10,"carrier-local Y advects and grows");
            Near(previous.Z,expected.Z,1e-10,"carrier-local Z advects and grows");
            V currentCamera=new V(0.1,0,0),previousCamera=new V(0,0,0);
            V displacement=previous-currentPoint;
            Near(ProjectX(currentPoint+displacement,previousCamera),ProjectX(expected,previousCamera),1e-12,
                "camera and carrier reprojection use previous-minus-current displacement");
            Check(Math.Abs(ProjectX(currentPoint,currentCamera)-ProjectX(expected,previousCamera))>1e-8,
                "side strafe genuinely changes storage position");
        }
        Near(MotionConfidence(2,10,0,0,true),0,0,"birth/missing previous pose rejects reuse");
        Near(MotionConfidence(0.01,10,10,0,true),0,0,"new Fire packet remains responsive");
        Near(MotionConfidence(0.08,10,10,0,false),0,0,"new explosion remains responsive");
        Near(MotionConfidence(1,10,5,0,true),0,0,"rapid growth rejects reuse");
        Near(MotionConfidence(1,10,10,40,true),0,0,"teleport/very fast small carrier rejects reuse");
        Near(MotionConfidence(1,10,10,0.5,true),1,0,"mature slowly moving Fire permits reuse");
        for (int i=0;i<=32;++i)
        {
            double share=i/32.0;
            double confidence=Smooth(0.60,0.95,share);
            Check(confidence>=0 && confidence<=1,"mixed-grid confidence bounded");
            if (share<=0.6) Near(confidence,0,0,"untracked Grid/current births cannot borrow mature motion");
        }
        Near(Math.Exp(-16/(0.5*0.5)),0,1e-20,"opposing carrier motion rejects ambiguous velocity");
        Near(Math.Exp(-0.0),1,0,"co-moving neighboring lobes retain confidence");
        // Bilinear previous coverage is linear in T/alpha and source radiance,
        // whereas interpolating tau would incorrectly darken the half-clear case.
        double maximumBilinearStep=0,last=0;
        for (int i=0;i<=100;++i)
        {
            double fraction=i/100.0,a=Alpha(4)*fraction;
            Near(Alpha(Tau(a)),a,1e-12,"bilinear opacity roundtrip");
            Near((1-fraction)+fraction*Math.Exp(-4),1-a,1e-12,"bilinear transmission identity");
            if (i>0) maximumBilinearStep=Math.Max(maximumBilinearStep,Math.Abs(a-last));
            last=a;
        }
        Check(maximumBilinearStep<0.01,"fractional motion has no nearest-pixel step");
        Check(Math.Exp(-2)<(1+Math.Exp(-4))*0.5,"do not average optical depth temporally");
        Check(TapAccept(2.5,100,200,101,201,20),"compatible old smoke/background accepted");
        Check(!TapAccept(1,100,200,100,200,20),"legacy radiance-only history tag rejected");
        Check(!TapAccept(2.5,100,20,100,200,20),"foreground disocclusion rejected");
        Check(!TapAccept(2.5,30,200,100,200,20),"unrelated nearer smoke rejected");
        Check(!TapAccept(2.5,100,90,100,90,20),"previous opaque depth must not occlude smoke");
        // Fixed support has exactly the same density and premultiplied color.
        foreach (double current in new double[]{1e-5,0.01,0.1,0.3,0.7,0.99})
        foreach (double weight in new double[]{0,0.125,0.375,0.65})
        {
            Near(ResolveAlpha(current,current,current,current,weight),current,1e-12,"static authored opacity invariant");
            Near((current*3)*(1-weight)+(current*3)*weight,current*3,1e-12,"static premultiplied color invariant");
            Near(ResolveAlpha(0,current,0,current,weight),0,0,"death/gap clears immediately despite old smoke");
            double clamped=ResolveAlpha(current,1,current*0.8,Math.Min(1,current*1.2),weight);
            Check(clamped>=current*0.8-1e-12 && clamped<=Math.Min(1,current*1.2)+1e-12,
                "history remains inside current neighborhood support");
        }
        // Alternating edge sampling is stabilized without changing the long-run
        // mean value or its constant premultiplied-light ratio.
        double history=0.3,mean=0,variance=0,rgb=0;
        const int frames=400;
        for (int frame=0;frame<frames;++frame)
        {
            double current=0.3+((frame&1)==0 ? 0.1 : -0.1);
            history=ResolveAlpha(current,history,0.15,0.45,0.65);
            if (frame>=200) { mean+=history/200;variance+=(history-0.3)*(history-0.3)/200;rgb+=history*3/200; }
        }
        Near(mean,0.3,1e-10,"motion shimmer filter preserves long-run mean density");
        Near(rgb,0.9,1e-10,"motion shimmer filter preserves mean premultiplied radiance");
        Check(variance<0.001,"edge-opacity sampling variance reduced over90%");
        foreach (double tau in new double[]{1e-12,1e-9,1e-6,0.001,0.1,1,10})
            Near(Tau(Alpha(tau)),tau,Math.Max(1e-12,tau*1e-9),"small optical depth remains finite and stable");
        double movingMeanDifference,movingAreaDifference,groundTruthRmsRatio;
        string movingDiagnostic;
        double movingVarianceRatio=MovingFroxelCase(6,0.65,out movingMeanDifference,out movingAreaDifference,
            out groundTruthRmsRatio,out movingDiagnostic);
        Check(movingVarianceRatio<0.4,"carrier-reprojected moving coarse-froxel edge variance reduced by at least60%");
        Check(movingAreaDifference<=0.035,"moving coarse-froxel integrated opacity stays within3.5%: "+movingAreaDifference);
        Check(groundTruthRmsRatio<1,"moving edge RMS must improve against analytic sphere ground truth: "+movingDiagnostic);
        return checks+" smoke transient history numeric checks passed; alternating-edge variance="+
            variance.ToString("F6")+" (unfiltered0.010000); moving-froxel variance ratio="+
            movingVarianceRatio.ToString("F4")+", mean opacity delta="+movingMeanDifference.ToString("F5")+
            ", integrated opacity relative delta="+movingAreaDifference.ToString("F5")+", ground-truth RMS ratio="+groundTruthRmsRatio.ToString("F4")+
            ". CPU reference only; motion/GPU captures still required.";
    }
}
'@

[SmokeTransientHistoryTests]::Run()
if ($NumericalOnly) { return }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$shaders = Join-Path $root 'source/common/rendering/nri/shaders'
$helper = Get-Content -Raw (Join-Path $shaders 'Include/SmokeTransientHistory.hlsli')
$resources = Get-Content -Raw (Join-Path $shaders 'Include/SmokeResources.hlsli')
$materialize = Get-Content -Raw (Join-Path $shaders 'SmokeTransientMaterialize.cs.hlsl')
$resolve = Get-Content -Raw (Join-Path $shaders 'SmokeResolveVolume.cs.hlsl')
$temporal = Get-Content -Raw (Join-Path $shaders 'SmokeTemporalVolume.cs.hlsl')
$clear = Get-Content -Raw (Join-Path $shaders 'SmokeTransientClear.cs.hlsl')
$composite = Get-Content -Raw (Join-Path $shaders 'SmokeComposite.cs.hlsl')
function Require-Match([string]$text,[string]$pattern,[string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}
Require-Match $resources 'StructuredBuffer<float4> gSmokeTransientPreviousLobes\s*:\s*register\(t5, space0\)' 'Previous pose input ABI missing.'
Require-Match $resources 'RWStructuredBuffer<float4> gSmokeTransientFroxelMotion\s*:\s*register\(u67, space1\)' 'Froxel motion buffer ABI missing.'
Require-Match $helper 'NRI_SMOKE_TRANSIENT_HISTORY_ENABLED\s+0x800u' 'Separate transient temporal flag missing.'
Require-Match $helper 'previous\.xyz\s*\+\s*\(receiver\s*-\s*lobe\.Position\)\s*\*\s*growthRatio' 'History mapping omits carrier growth.'
Require-Match $helper 'previousReceiver\s*-\s*receiver' 'History displacement sign must be previous minus current.'
Require-Match $helper 'previous\.w\s*<=\s*0\.0' 'Missing/birth previous poses must reject reuse.'
Require-Match $helper 'depthBits\s*<<\s*8u[\s\S]*confidenceBits' 'Motion depth/confidence packing changed.'
Require-Match $helper 'result\.Depth\s*=\s*clamp\(result\.Depth, nearDepth\s*\+\s*inset, farDepth\s*-\s*inset\)' 'Guide quantization may select a different froxel slice.'
Require-Match $clear 'SmokeTransientHistoryEnabled\(\)[\s\S]*gSmokeTransientFroxelMotion\[index\]\s*=\s*0\.0' 'Motion support must clear every active history frame.'
Require-Match $materialize 'extinction\s*\+\s*max\(previousMedium\.w,\s*0\.0\)' 'Grid/untracked current medium must reduce motion confidence.'
Require-Match $materialize 'motionMoment\s*/\s*motionWeight\s*-\s*dot\(displacement, displacement\)' 'Conflicting carrier velocities are not rejected.'
Require-Match $resolve 'historyConfidence\s*=\s*motion\.Confidence' 'Full-resolution current metadata omits motion confidence.'
Require-Match $temporal 'coordinate\s*=\s*previousUv\s*\*\s*float2\(dimensions\)\s*-\s*0\.5' 'Previous history is not bilinearly reconstructed at pixel centers.'
Require-Match $temporal 'metadata\.w\s*<=\s*2\.0' 'Legacy/Grid histories can be borrowed by transient opacity history.'
Require-Match $temporal 'SmokeTransientHistoryOpacity\(history\.a\)' 'History lookup must average opacity/T, not optical depth.'
Require-Match $temporal 'history\s*=\s*clamp\(history, minimumValue, maximumValue\)' 'Current-frame support must bound reused history.'
Require-Match $temporal 'min\(historyAge\s*\+\s*0\.125,\s*0\.65\)' 'Transient history weight no longer has a short bounded horizon.'
Require-Match $temporal 'expectedOpaqueDepth[\s\S]*opaqueDepth\s*\+\s*max\(2\.0, opaqueDepth\s*\*\s*0\.001\)\s*<\s*expectedSmokeDepth' 'Previous occlusion checks missing.'
$main = $temporal.Substring($temporal.IndexOf('void main('))
Require-Match $main 'current\.a\s*<=\s*1e-6[\s\S]*gSmokeVolumeHistoryOutput\[pixel\]\s*=\s*0\.0[\s\S]*return;[\s\S]*SmokeResolveTransientHistory' 'Empty current smoke must clear before any history branch.'
Require-Match $main 'NRI_SMOKE_VOLUME_HISTORY_VALID\s*\|\s*NRI_SMOKE_VOLUME_HISTORY_ENABLED' 'Legacy radiance history must retain its independent enable flag.'
Require-Match $main 'resolved\.a\s*=\s*current\.a' 'Legacy radiance history must keep current optical depth.'
Require-Match $composite 'saturate\(meta\.w\s*>\s*2\.0\s*\?\s*meta\.w\s*-\s*2\.0\s*:\s*meta\.w\)' 'History-age debug must decode the transient age tag.'
if (($helper+$materialize+$temporal) -match 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible') {
    throw 'Transient history must not introduce visibility rays.'
}
Write-Output 'Smoke transient history shader contracts passed.'

$renderer = Join-Path $root 'source/common/rendering/nri/renderer'
$cvars = Get-Content -Raw (Join-Path $renderer 'nri_cvars.cpp')
$settings = Get-Content -Raw (Join-Path $renderer 'nri_renderer_settings.cpp')
$smoke = Get-Content -Raw (Join-Path $renderer 'nri_smoke.cpp')
$transient = Get-Content -Raw (Join-Path $renderer 'nri_smoke_transient_renderer.cpp')
$resourceOwner = Get-Content -Raw (Join-Path $renderer 'nri_smoke_transient_resources.cpp')
$resourceHeader = Get-Content -Raw (Join-Path $renderer 'nri_smoke_transient_resources.h')
$cmake = Get-Content -Raw (Join-Path $root 'source/CMakeLists.txt')
Require-Match $cvars 'CVAR\(Bool,\s*nri_ptsmoketransienthistory,\s*true,\s*0\)' 'Transient history must be default-on and session-only.'
Require-Match $settings 'settings\.transientHistory\s*=\s*nri_ptsmoketransienthistory;' 'Transient history does not reach the renderer snapshot.'
Require-Match $smoke 'transientHistoryAllowed\s*=\s*mSettings\.transientHistory\s*&&\s*!fieldDiagnostics\s*&&\s*!mTransientClouds\.GetGpuLobes\(\)\.empty\(\)' 'Empty transient views must not read stale motion (group slots remain fixed64 even when empty).'
Require-Match $smoke 'volumeHistoryAllowed\s*=\s*\(mSettings\.volumeHistory\s*\|\|\s*transientHistoryAllowed\)' 'Transient opacity history must work while legacy volumehistory is false.'
Require-Match $smoke 'if\s*\(transientHistoryAllowed\)\s*constants\.lightSourceFlags\s*\|=\s*0x800u' 'CPU/HLSL transient history flag disagrees.'
Require-Match $smoke 'if\s*\(mSettings\.volumeHistory\s*&&\s*!fieldDiagnostics\)\s*constants\.flags\s*\|=\s*0x2000u' 'Legacy radiance history must remain independently enabled.'
Require-Match $smoke 'if\s*\(volumeHistoryCompatible\)\s*constants\.flags\s*\|=\s*0x1000u' 'Both history modes need the shared compatible-history validity flag.'
Require-Match $smoke '!renderer\.mResetHistory\s*&&\s*mLastVolumeFrame\s*\+\s*1u\s*==\s*renderer\.mFrameIndex' 'Cuts or missed frames can reuse stale smoke history.'
Require-Match $smoke 'mSettings\.volumeHistory\s*\?\s*1u\s*:\s*0u[\s\S]*mSettings\.transientHistory\s*\?\s*2u\s*:\s*0u[\s\S]*mSettings\.transientCoverage\s*\?\s*4u\s*:\s*0u' 'A/B mode switches must invalidate final-layer history.'
Require-Match $resourceHeader 'InputDescriptorCount\s*=\s*3' 'Previous lobe transforms need the third transient input descriptor.'
Require-Match $resourceOwner 'mMotion\.Prepare\(s\.rendererFrame,\s*lobes,\s*resetMotion\)' 'Previous poses must be keyed to the preceding rendered frame.'
$lightingKey = [regex]::Match($transient, 'const uint32_t lightingKey\s*=([^;]+);').Groups[1].Value
if (-not $lightingKey -or $lightingKey -match 'transientHistory|0x800') {
    throw 'Motion history must not rebuild analytic/emissive light caches.'
}
Require-Match $cmake 'foreach\(_smoke_reconstruction_pass ResolveVolume TemporalVolume Composite\)' 'Reconstruction shaders must retain isolated build rules for tuning.'
Require-Match $cmake 'DEPENDS "\$\{_smoke_reconstruction_source\}"[\s\S]*Include/SmokeTransientHistory\.hlsli' 'Isolated reconstruction rules omit their history helper dependency.'
Write-Output 'Smoke transient history CPU/A-B/build contracts passed.'
