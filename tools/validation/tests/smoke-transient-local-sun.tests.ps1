param([switch]$NumericalOnly)

$ErrorActionPreference = 'Stop'

# Independent double-precision reference checks for Fire's local directional
# penetration. These are CPU tests, not GPU image/performance validation. The
# shape oracle samples the plateau density directly; it does not reuse the
# analytic primitive when checking the integral.
Add-Type -TypeDefinition @'
using System;

public static class SmokeTransientLocalSunTests
{
    public struct V
    {
        public double X, Y, Z;
        public V(double x, double y, double z) { X = x; Y = y; Z = z; }
        public static V operator +(V a, V b) { return new V(a.X+b.X, a.Y+b.Y, a.Z+b.Z); }
        public static V operator -(V a, V b) { return new V(a.X-b.X, a.Y-b.Y, a.Z-b.Z); }
        public static V operator *(V a, double b) { return new V(a.X*b, a.Y*b, a.Z*b); }
        public double Dot(V b) { return X*b.X + Y*b.Y + Z*b.Z; }
        public double Length() { return Math.Sqrt(Dot(this)); }
        public V Unit() { return this * (1.0 / Length()); }
    }

    public sealed class Lobe
    {
        public V Center;
        public double Radius, Plateau, Density;
        public Lobe(V center, double radius, double plateau, double density)
        { Center=center; Radius=radius; Plateau=plateau; Density=density; }
    }

    static int checks;
    static bool Finite(double x) { return !Double.IsNaN(x) && !Double.IsInfinity(x); }
    static void Check(bool condition, string message)
    {
        ++checks;
        if (!condition) throw new Exception(message);
    }
    static void Near(double actual, double expected, double tolerance, string message)
    {
        Check(Finite(actual) && Finite(expected) && Math.Abs(actual-expected) <= tolerance,
            message + " (actual=" + actual + ", expected=" + expected + ")");
    }
    static double Clamp(double value, double lo, double hi)
    { return Math.Max(lo, Math.Min(hi, value)); }

    static double Primitive(double q, double radial, double denominator)
    { return (radial*q - q*q*q/3.0) / denominator; }

    static double Integral(Lobe lobe, V origin, V unitRay, double segmentNear, double segmentFar)
    {
        double radius = Math.Max(lobe.Radius, 0.001);
        double rr = radius*radius;
        double closest = (lobe.Center-origin).Dot(unitRay);
        V perpendicular = origin + unitRay*closest - lobe.Center;
        double impact2 = perpendicular.Dot(perpendicular);
        if (impact2 >= rr) return 0.0;
        double outerHalf = Math.Sqrt(Math.Max(rr-impact2, 0.0));
        double q0 = Math.Max(segmentNear-closest, -outerHalf);
        double q1 = Math.Min(segmentFar-closest, outerHalf);
        if (q1 <= q0) return 0.0;
        double plateau = Clamp(lobe.Plateau, 0.0, 0.95);
        double core2 = rr*plateau*plateau;
        double denominator = Math.Max(rr-core2, rr*0.0975);
        double radial = rr-impact2;
        double shell = Math.Max(Primitive(q1,radial,denominator)-Primitive(q0,radial,denominator), 0.0);
        double core = 0.0;
        if (impact2 < core2)
        {
            double coreHalf = Math.Sqrt(Math.Max(core2-impact2, 0.0));
            double c0 = Math.Max(q0, -coreHalf), c1 = Math.Min(q1, coreHalf);
            if (c1 > c0)
            {
                core = c1-c0;
                shell = Math.Max(shell-Math.Max(Primitive(c1,radial,denominator)-
                    Primitive(c0,radial,denominator), 0.0), 0.0);
            }
        }
        return (core+shell)*Math.Max(lobe.Density, 0.0);
    }

    static double DensityAt(Lobe lobe, V position)
    {
        double radius = Math.Max(lobe.Radius, 0.001);
        double rr = radius*radius;
        V delta = position-lobe.Center;
        double distance2 = delta.Dot(delta);
        double plateau = Clamp(lobe.Plateau, 0.0, 0.95);
        if (distance2 >= rr) return 0.0;
        if (distance2 <= rr*plateau*plateau) return Math.Max(lobe.Density, 0.0);
        return Clamp((rr-distance2)/Math.Max(rr*(1.0-plateau*plateau),rr*0.0975),0.0,1.0)*
            Math.Max(lobe.Density, 0.0);
    }

    static double NumericalIntegral(Lobe[] lobes, V origin, V unitRay,
        double segmentNear, double segmentFar)
    {
        const int steps = 32768;
        double width=(segmentFar-segmentNear)/steps, sum=0.0;
        for (int i=0; i<steps; ++i)
        {
            V position=origin+unitRay*(segmentNear+(i+0.5)*width);
            foreach (Lobe lobe in lobes) sum += DensityAt(lobe,position)*width;
        }
        return sum;
    }

    static double GroupDepth(Lobe[] lobes, V origin, V lightDirection, double maximumDistance)
    {
        double result=0.0;
        V unitRay=lightDirection.Unit();
        foreach (Lobe lobe in lobes) result += Integral(lobe,origin,unitRay,0.001,maximumDistance);
        return Math.Max(Finite(result) ? result : 0.0,0.0);
    }

    // Preserve the established Fire transport floor; option 2 relocates its
    // optical-depth receiver without retuning extinction, albedo, or that floor.
    static double Self(double opticalDepth, bool enabled)
    { return enabled ? 0.18+0.82*Math.Exp(-Clamp(opticalDepth,0.0,20.0)) : 1.0; }

    static double Transport(double sceneVisibility, double opticalDepth, bool selfEnabled)
    { return (Finite(sceneVisibility) ? Clamp(sceneVisibility,0.0,1.0) : 0.0)*Self(opticalDepth,selfEnabled); }

    static bool SegmentReceiver(Lobe lobe, V origin, V unitRay,
        double segmentNear, double segmentFar, out V receiver)
    {
        receiver=lobe.Center;
        if (!Finite(lobe.Radius) || lobe.Radius <= 0.0 || segmentFar <= segmentNear) return false;
        double radius=lobe.Radius, rr=radius*radius;
        double closest=(lobe.Center-origin).Dot(unitRay);
        V perpendicular=origin+unitRay*closest-lobe.Center;
        double impact2=perpendicular.Dot(perpendicular);
        if (!(rr-impact2 > 0.0)) return false;
        double halfChord=Math.Sqrt(Math.Max(rr-impact2,0.0));
        double entry=Math.Max(segmentNear,closest-halfChord);
        double exit=Math.Min(segmentFar,closest+halfChord);
        if (exit <= entry) return false;
        receiver=origin+unitRay*((entry+exit)*0.5);
        return Finite(receiver.X) && Finite(receiver.Y) && Finite(receiver.Z);
    }

    static V StrongestReceiver(Lobe[] lobes, V origin, V rawRay,
        double nearDepth, double farDepth, out double winningWeight)
    {
        double rayLength=rawRay.Length();
        V unitRay=rawRay.Unit(), result=new V();
        winningWeight=0.0;
        foreach (Lobe lobe in lobes)
        {
            double weight=Integral(lobe,origin,unitRay,nearDepth*rayLength,farDepth*rayLength)/
                ((farDepth-nearDepth)*rayLength);
            V receiver;
            if (weight > winningWeight && SegmentReceiver(lobe,origin,unitRay,
                nearDepth*rayLength,farDepth*rayLength,out receiver))
            { result=receiver; winningWeight=weight; }
        }
        return result;
    }

    public static string Run()
    {
        checks=0;
        V zero=new V(0,0,0), sun=new V(1,0,0);
        Lobe sphere=new Lobe(zero,2.0,0.58,1.2);
        Lobe[] single={sphere};
        double facing=GroupDepth(single,new V(1.7,0,0),sun,20.0);
        double interior=GroupDepth(single,zero,sun,20.0);
        double back=GroupDepth(single,new V(-1.7,0,0),sun,20.0);
        double thin=GroupDepth(single,new V(0,1.95,0),sun,20.0);
        Check(facing < interior && interior < back,"Directional depth must grow from the sun-facing shell through the interior to the rear.");
        Check(Self(facing,true) > Self(interior,true) && Self(interior,true) > Self(back,true),
            "Sunlight must reveal exposed shoulders without flattening the dark interior.");
        Check(Self(thin,true) > Self(interior,true),"Thin smoke must transmit more directional light than the dense core.");
        Near(GroupDepth(single,new V(1.7,0,0),new V(-1,0,0),20.0),back,1e-12,
            "Reversing the sun did not swap the spherical bright and dark sides.");
        Near(GroupDepth(single,new V(1.7,0,0),new V(5,0,0),20.0),facing,1e-12,
            "Light direction normalization changed optical depth.");

        Lobe overlap=new Lobe(new V(1.0,0.2,0),1.8,0.4,0.7);
        Lobe[] combined={sphere,overlap};
        double overlapOnly=GroupDepth(new Lobe[]{overlap},zero,sun,20.0);
        double combinedDepth=GroupDepth(combined,zero,sun,20.0);
        Near(combinedDepth,interior+overlapOnly,1e-12,"Overlapping group lobes must add optical depth without signed cancellation.");
        Check(Self(combinedDepth,true) <= Self(interior,true),"An overlapping lobe brightened the receiver.");
        Near(GroupDepth(new Lobe[]{sphere,sphere},zero,sun,20.0),2.0*interior,1e-12,
            "Duplicate overlapping lobes did not preserve authored density addition.");
        Lobe behind=new Lobe(new V(-5,0,0),1.0,0.5,3.0);
        Near(GroupDepth(new Lobe[]{sphere,behind},zero,sun,20.0),interior,1e-12,
            "Smoke wholly behind a receiver occluded its forward sunlight.");

        // Independent numerical density quadrature, including partial chords,
        // different plateau values, off-axis rays, and coincident/offset lobes.
        Random random=new Random(27419);
        for (int i=0;i<64;++i)
        {
            Lobe a=new Lobe(new V(random.NextDouble()*2-1,random.NextDouble()*2-1,
                random.NextDouble()*2-1),0.3+random.NextDouble()*3,
                random.NextDouble()*0.95,0.2+random.NextDouble()*2);
            Lobe b=new Lobe(new V(random.NextDouble()*2-1,random.NextDouble()*2-1,
                random.NextDouble()*2-1),0.3+random.NextDouble()*3,
                random.NextDouble()*0.95,0.2+random.NextDouble()*2);
            V origin=new V(random.NextDouble()*4-2,random.NextDouble()*4-2,random.NextDouble()*4-2);
            V direction=new V(random.NextDouble()+0.1,random.NextDouble()-0.5,random.NextDouble()-0.5).Unit();
            Lobe[] lobes={a,b};
            double distance=0.1+random.NextDouble()*8;
            Near(GroupDepth(lobes,origin,direction,distance),
                NumericalIntegral(lobes,origin,direction,0.001,distance),0.00002,
                "Analytic local group depth disagrees with independently sampled density at case "+i+".");
        }

        // The original froxel center is outside smoke, but the positive line
        // integral still contributes. An unclipped receiver would miss its local
        // shaping entirely for this perpendicular sun direction.
        Lobe partial=new Lobe(new V(0,0,2.5),0.4,0.5,1.0);
        V viewRay=new V(0,0,1), receiver;
        Check(SegmentReceiver(partial,zero,viewRay,2.0,8.0,out receiver),"A partially occupied froxel lost its contributing support.");
        Check(DensityAt(partial,new V(0,0,5)) == 0.0,"Partial-segment fixture no longer has an empty froxel center.");
        Check(DensityAt(partial,receiver) > 0.0,"Clipped receiver escaped the contributing lobe.");
        Near(receiver.Z,2.5,1e-12,"Symmetric clipped support did not choose its midpoint.");
        Check(GroupDepth(new Lobe[]{partial},receiver,sun,20.0) > 0.0,
            "Partial-support local receiver did not see smoke on its sun ray.");
        Near(GroupDepth(new Lobe[]{partial},new V(0,0,5),sun,20.0),0.0,0.0,
            "Partial-segment fixture no longer detects the raw-center failure.");
        Check(SegmentReceiver(partial,zero,viewRay,2.7,8.0,out receiver),"A clipped half-lobe was rejected.");
        Near(receiver.Z,2.8,1e-12,"Half-lobe support midpoint used unclipped sphere bounds.");
        Check(!SegmentReceiver(partial,zero,viewRay,4.0,8.0,out receiver),"A disjoint view segment acquired a local smoke receiver.");
        Check(!SegmentReceiver(new Lobe(new V(1,0,3),1,0.5,1),zero,viewRay,0,8,out receiver),
            "A tangent-only intersection acquired positive support.");
        foreach (double radius in new double[]{0,-1,Double.NaN,Double.PositiveInfinity})
            Check(!SegmentReceiver(new Lobe(zero,radius,0.5,1),zero,viewRay,0,8,out receiver),
                "A nonpositive or nonfinite radius acquired a support receiver.");
        Check(!SegmentReceiver(partial,zero,viewRay,8,2,out receiver),"A reversed froxel segment acquired a support receiver.");
        Check(!SegmentReceiver(new Lobe(new V(Double.NaN,0,0),1,0.5,1),zero,viewRay,0,8,out receiver),
            "A nonfinite center acquired a support receiver.");

        // Unequal or disconnected lobes must not average their receiver into an
        // empty gap. Strict > keeps ties deterministic in authored lobe order.
        Lobe nearLobe=new Lobe(new V(0,0,2),0.5,0.5,1.0);
        Lobe farLobe=new Lobe(new V(0,0,8),0.5,0.5,2.0);
        double winningWeight;
        V strongest=StrongestReceiver(new Lobe[]{nearLobe,farLobe},zero,new V(0,0,2),
            0.0,5.0,out winningWeight);
        Check(winningWeight > 0.0 && DensityAt(farLobe,strongest) > 0.0,
            "Strongest-lobe receiver used empty space or failed non-unit view-ray depth conversion.");
        Near(strongest.Z,8.0,1e-12,"Dominant lobe did not own the single group/froxel receiver.");
        Check(DensityAt(nearLobe,new V(0,0,5))+DensityAt(farLobe,new V(0,0,5)) == 0.0,
            "Disconnected-lobe fixture no longer detects the centroid gap.");
        farLobe.Density=1.0;
        strongest=StrongestReceiver(new Lobe[]{nearLobe,farLobe},zero,viewRay,0,10,out winningWeight);
        Near(strongest.Z,2.0,1e-12,"Equal-contribution selection is not deterministic in lobe order.");

        // Selection switches at an equal-weight crossing. This is an explicit
        // one-receiver approximation, not exact froxel lighting quadrature.
        farLobe.Density=1.0001;
        strongest=StrongestReceiver(new Lobe[]{nearLobe,farLobe},zero,viewRay,0,10,out winningWeight);
        Near(strongest.Z,8.0,1e-12,"The selected receiver failed to track a new strongest contribution.");

        double prior=1.0;
        foreach (double tau in new double[]{-1,0,0.01,0.1,1,4,20,1e9})
        {
            double local=Self(tau,true);
            Check(Finite(local) && local >= 0.18 && local <= 1.0 && local <= prior,
                "Fire local transport must remain finite, bounded, and monotonic.");
            prior=local;
            Near(Transport(0.0,tau,true),0.0,0.0,"The artistic Fire floor leaked through blocked scene visibility.");
            Near(Transport(0.4,tau,true),0.4*local,1e-12,"Cached building visibility was not multiplicative.");
            Near(Transport(0.4,tau,false),0.4,0.0,"Disabling self shadow also disabled building visibility.");
            Near(Self(tau,false),1.0,0.0,"Self-shadow-disabled mode retained packet attenuation.");
            // A full unoccluded bank and a coarse unoccluded fallback must use
            // the same current local factor, avoiding a new self-shadow ramp.
            Near(Transport(1.0,tau,true),local,0.0,"Unoccluded fallback/full local factors disagree.");
        }
        Near(Transport(Double.NaN,1,true),0.0,0.0,"NaN cached scene visibility was accepted.");
        Near(Transport(Double.PositiveInfinity,1,true),0.0,0.0,"Infinite cached scene visibility was accepted.");
        Near(Transport(-1,1,true),0.0,0.0,"Negative scene visibility was accepted.");
        Near(Transport(2,1,true),Self(1,true),0.0,"Scene visibility above one was not clamped.");
        Near(GroupDepth(new Lobe[0],zero,sun,20.0),0.0,0.0,"Empty groups acquired optical depth.");

        // Hoisting the common directional transport out of the lobe loop must
        // retain each contributing style's own scattering and phase response.
        double[] sigmaS={0.2,0.7,1.3}, phase={0.03,0.08,0.21};
        double localTransport=Transport(0.4,interior,true), sunColor=2.5;
        double perLobe=0.0, accumulatedScattering=0.0;
        for (int i=0;i<sigmaS.Length;++i)
        {
            perLobe += sigmaS[i]*phase[i]*sunColor*localTransport;
            accumulatedScattering += sigmaS[i]*phase[i];
        }
        Near(accumulatedScattering*sunColor*localTransport,perLobe,1e-12,
            "One group directional application changed mixed-style scattering/phase response.");

        return "Smoke transient local-sun CPU reference: "+checks+" checks passed; facing/interior/back transport="+
            Self(facing,true).ToString("F6")+"/"+Self(interior,true).ToString("F6")+"/"+Self(back,true).ToString("F6")+".";
    }
}
'@

[SmokeTransientLocalSunTests]::Run()
if ($NumericalOnly) { return }

function Require-Match([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}
function Require-NoMatch([string]$text, [string]$pattern, [string]$message) {
    if ($text -match $pattern) { throw $message }
}
function Remove-ShaderComments([string]$text) {
    $withoutBlocks = [regex]::Replace($text, '/\*[\s\S]*?\*/', '')
    return [regex]::Replace($withoutBlocks, '(?m)//[^\r\n]*', '')
}
function Get-CodeBlock([string]$text, [string]$pattern) {
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "Missing code-block pattern: $pattern" }
    $open = $text.IndexOf('{', $match.Index + $match.Length)
    if ($open -lt 0) { throw "Missing opening brace after: $pattern" }
    $depth = 1
    for ($index = $open + 1; $index -lt $text.Length; ++$index) {
        if ($text[$index] -eq '{') { ++$depth }
        elseif ($text[$index] -eq '}') { --$depth }
        if ($depth -eq 0) {
            return [pscustomobject]@{
                Text = $text.Substring($open + 1, $index - $open - 1)
                Open = $open
                Close = $index
            }
        }
    }
    throw "Unclosed code block after: $pattern"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$lighting = Get-Content -Raw (Join-Path $root 'source/common/rendering/nri/shaders/Include/SmokeTransientLighting.hlsli')
$materialize = Get-Content -Raw (Join-Path $root 'source/common/rendering/nri/shaders/SmokeTransientMaterialize.cs.hlsl')
$build = Get-Content -Raw (Join-Path $root 'source/common/rendering/nri/shaders/SmokeTransientLightBuild.cs.hlsl')
$lightingCode = Remove-ShaderComments $lighting
$materializeCode = Remove-ShaderComments $materialize
$buildCode = Remove-ShaderComments $build

# Structural wiring checks intentionally accompany, rather than replace, the
# numeric oracle and compiled/runtime image validation.
Require-Match $lightingCode 'bool\s+SmokeTransientSphereSegmentReceiver\s*\(' 'The shared clipped-support receiver helper is missing.'
$receiverCode = (Get-CodeBlock $lightingCode 'bool\s+SmokeTransientSphereSegmentReceiver\s*\([^)]*\)').Text
Require-Match $receiverCode '!isfinite\(radius\)\s*\|\|\s*radius\s*<=\s*0\.0\s*\|\|\s*segmentFar\s*<=\s*segmentNear' 'Invalid sphere/segment inputs are not rejected before receiver selection.'
Require-Match $receiverCode 'entry\s*=\s*max\(segmentNear,\s*closest\s*-\s*halfChord\)' 'The receiver chord is not clipped to the froxel near bound.'
Require-Match $receiverCode 'exit\s*=\s*min\(segmentFar,\s*closest\s*\+\s*halfChord\)' 'The receiver chord is not clipped to the froxel far bound.'
Require-Match $receiverCode 'if\s*\(exit\s*<=\s*entry\)\s*return\s+false' 'Empty clipped support is not rejected.'
Require-Match $receiverCode 'receiverPosition\s*=\s*rayOrigin\s*\+\s*unitRay\s*\*\s*\(\(entry\s*\+\s*exit\)\s*\*\s*0\.5\)' 'The receiver is not the occupied chord midpoint.'
Require-Match $receiverCode 'return\s+all\(isfinite\(receiverPosition\)\)' 'The chosen receiver is not checked for finite coordinates.'

$directionalBuild = (Get-CodeBlock $buildCode 'if\s*\(gSmokeConstants\.LightMode\s*>\s*0u\s*&&\s*\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_LIGHT_SOURCE_DIRECTIONAL\)\s*!=\s*0u\)').Text
Require-Match $directionalBuild 'directionalTransport\s*=\s*group\.TransientClass\s*==\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*\?\s*visibility\s*:\s*visibility\s*\*\s*selfTransmittance' 'Fire must cache scene visibility alone while non-Fire retains the old combined transport.'
Require-Match $directionalBuild 'if\s*\(fullBuild\s*&&\s*group\.TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*&&' 'Fire cache construction still spends a directional group self-depth integral.'
Require-Match $directionalBuild 'if\s*\(group\.TransientClass\s*!=\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\)\s*SmokeTransientAccumulateIncident' 'Fire sun radiance is double-counted in the cached incident lobes.'

$mainCode = (Get-CodeBlock $materializeCode 'void\s+main\s*\([^)]*\)').Text
$lobeLoop = Get-CodeBlock $mainCode 'for\s*\(uint\s+lobeIndex\s*=\s*group\.FirstLobe;[^)]*\)'
Require-NoMatch $lobeLoop.Text 'SmokeTransientGroupOpticalDepth\s*\(' 'Materialization evaluates a whole-group sun integral inside its contributing-lobe loop.'
Require-Match $lobeLoop.Text 'groupDirectionalScattering\s*\+=\s*sigmaS\s*\*\s*SmokePhaseResponse\(dot\(directionalDirection,\s*viewRay\),\s*style\.Anisotropy\)' 'Hoisted sun application lost per-lobe scattering or anisotropy.'
Require-Match $lobeLoop.Text 'sigmaT\s*>\s*directionalReceiverWeight' 'Receiver selection is not strictly strongest-contribution with deterministic ties.'
Require-Match $lobeLoop.Text 'SmokeTransientSphereSegmentReceiver\(lobe\.Position,\s*supportRadius,\s*gSmokeConstants\.CameraPosition,\s*viewRay,\s*nearDepth\s*\*\s*rayLength,\s*farDepth\s*\*\s*rayLength,\s*receiverPosition\)' 'Receiver selection does not convert froxel view depths into world-space chord distances.'
Require-Match $lobeLoop.Text 'directionalReceiverWeight\s*=\s*sigmaT;\s*directionalReceiverPosition\s*=\s*receiverPosition' 'The supported strongest-lobe receiver and its weight are not updated coherently.'
Require-Match $lobeLoop.Text 'SmokeTransientResolveIncident\(samplePosition,\s*group,\s*lightAnchors' 'The local sun receiver moved the shared cached analytic/emissive interpolation position.'
Require-Match $lobeLoop.Text 'extinction\s*\+=\s*sigmaT;\s*scattering\s*\+=\s*sigmaS;' 'Local sunlight changed the accumulated medium extinction/scattering coefficients.'
Require-NoMatch $lobeLoop.Text '(sigmaT|sigmaS)\s*[*+]\=\s*(directionalTransport|localSelfTransmittance)' 'Local sunlight was applied to medium coefficients rather than source radiance.'

$localSun = Get-CodeBlock $mainCode 'if\s*\(groupContributed\s*&&\s*cacheValid\s*&&\s*localDirectional\)'
if ($localSun.Open -le $lobeLoop.Close) { throw 'Local sunlight is not applied after the contributing-lobe loop.' }
$depthCalls = [regex]::Matches($mainCode, 'SmokeTransientGroupOpticalDepth\s*\(').Count
if ($depthCalls -ne 1) { throw "Expected one local self-depth call site in materialization, found $depthCalls." }
Require-Match $mainCode 'localDirectional\s*=\s*group\.TransientClass\s*==\s*NRI_SMOKE_TRANSIENT_CLASS_FIRE\s*&&\s*gSmokeConstants\.LightMode\s*>\s*0u\s*&&\s*\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_LIGHT_SOURCE_DIRECTIONAL\)\s*!=\s*0u' 'The local sun path is not restricted to Fire with directional lighting enabled.'
Require-Match $localSun.Text 'localSelfTransmittance\s*=\s*1\.0;' 'Disabled local self-shadowing does not start from identity transport.'
Require-Match $localSun.Text 'LightSourceFlags\s*&\s*NRI_SMOKE_TRANSIENT_SELF_SHADOW\)\s*!=\s*0u\s*&&\s*directionalReceiverWeight\s*>\s*0\.0' 'Local self depth ignores the self-shadow toggle or support-validity condition.'
Require-Match $localSun.Text 'localSelfTransmittance\s*=\s*SmokeTransientSelfTransmittance\(group,\s*SmokeTransientGroupOpticalDepth\(group,\s*directionalReceiverPosition,\s*directionalDirection,\s*100000\.0\)\)' 'Local sun does not integrate the current group from its smoke-supported receiver.'
Require-Match $localSun.Text 'groupSource\s*\+=\s*groupDirectionalScattering\s*\*\s*SmokeDirectionalColor\(\)\s*\*\s*directionalTransport\s*\*\s*localSelfTransmittance' 'Local self attenuation and cached scene visibility are not separate multiplicative factors.'
Require-NoMatch $localSun.Text 'PublishedState|NRI_SMOKE_TRANSIENT_LIGHT_FULL|NRI_SMOKE_TRANSIENT_LIGHT_FALLBACK|currentWeight|SmokeTransientFireLightBlend' 'The local self factor is gated or crossfaded differently for fallback and FULL cache banks.'
$sourceClamp = $mainCode.IndexOf('source += min(groupSource, 32.0)')
if ($sourceClamp -le $localSun.Close) { throw 'Local sunlight bypasses or precedes the wrong group source-clamp boundary.' }

# Point and emissive lights deliberately retain their cache-built self depth;
# moving those would be an unrequested expansion of this directional-only slice.
foreach ($family in @('POINT', 'EMISSIVE')) {
    $familyPattern = 'if\s*\(gSmokeConstants\.LightMode\s*>\s*0u\s*&&\s*\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_LIGHT_SOURCE_' + $family + '\)\s*!=\s*0u\)'
    $familyCode = (Get-CodeBlock $buildCode $familyPattern).Text
    Require-Match $familyCode 'if\s*\(fullBuild\s*&&\s*\(gSmokeConstants\.LightSourceFlags\s*&\s*NRI_SMOKE_TRANSIENT_SELF_SHADOW\)' "$family cache no longer retains full-build self attenuation."
    Require-Match $familyCode 'SmokeTransientGroupOpticalDepth\(group,\s*receiverPosition,\s*direction,\s*distanceToLight\)' "$family cache no longer uses its receiver-to-light self-depth segment."
}
Require-NoMatch $materializeCode 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible' 'Local sunlight introduced a materialization-time scene ray.'
Require-NoMatch $lightingCode 'TraceRayInline|RayQuery|SmokePointLightVisible|SmokeEmissiveVisible' 'The shared local-sun math acquired ray-query implementation.'

Write-Output 'Smoke transient local-sun numerical and structural tests passed (CPU/reference only; validate shader compilation, captures, and GPU cost separately).'
