#include "nri_output.h"
#include "shaders/Include/HdrOutputMath.hlsli"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

namespace
{
	unsigned int checks = 0;

	void Check(bool condition, const char* message)
	{
		++checks;
		if (!condition)
		{
			std::cerr << "FAILED: " << message << '\n';
			std::exit(1);
		}
	}

	bool Near(float actual, float expected, float tolerance = 2.0e-5f)
	{
		return std::isfinite(actual) && std::abs(actual - expected) <= tolerance * std::max(1.0f, std::abs(expected));
	}

	float Clamp01(float value)
	{
		return std::clamp(value, 0.0f, 1.0f);
	}

	// These are the unchanged display-grading operators, not substitute tone maps.
	// The tone map, metadata policy and gamut scale below execute production math.
	float Grade(float value, float toe, float shoulder)
	{
		value = Clamp01(value);
		float weight = Clamp01(1.0f - value * 2.0f);
		value = value + (std::pow(value, toe) - value) * weight;
		weight = Clamp01(value * 2.0f - 1.0f);
		return value + (1.0f - std::pow(1.0f - value, shoulder) - value) * weight;
	}

	float Output(float input, unsigned int mode, const NRIPTOutputPolicy& policy, float toe = 1.0f, float shoulder = 1.0f)
	{
		const float peak = NriHdrSafePeak(policy.displaySdrLuminance, policy.displayMaxLuminance);
		const float headroom = GetNRIPTHdrHeadroomInPaperWhites(policy);
		return Grade(NriHdrTonemapChannel(input / headroom, mode), toe, shoulder) * (peak / 80.0f);
	}

	float ReferenceTonemap(float input, unsigned int mode)
	{
		const double x = input;
		if (mode == 1u)
			return static_cast<float>(((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)) / (2.51 / 2.43));
		if (mode == 2u)
			return static_cast<float>(x / (1.0 + x));
		return static_cast<float>((((x * (0.15 * x + 0.10 * 0.50) + 0.20 * 0.02) /
			(x * (0.15 * x + 0.50) + 0.20 * 0.30)) - 0.02 / 0.30) / (1.0 - 0.02 / 0.30));
	}

	void CheckMetadataAndCpuPolicy()
	{
		const float nan = std::numeric_limits<float>::quiet_NaN();
		const float inf = std::numeric_limits<float>::infinity();
		for (float invalid : { -inf, -2.0f, 0.0f, nan, inf })
		{
			Check(NriHdrSafeSdrWhite(invalid) == 80.0f, "invalid SDR metadata falls back to 80 nits");
			Check(GetNRIPTOutputSafeDisplaySdrLuminance(invalid) == 80.0f, "CPU SDR metadata fallback uses the same shared policy");
			Check(NriHdrSafePeak(240.0f, invalid) == 240.0f, "invalid peak falls back to safe SDR white");
			Check(NriHdrSafePeak(invalid, invalid) == 80.0f, "invalid peak and SDR metadata fall back to 80 nits");
		}
		Check(NriHdrSafeSdrWhite(0.1f) == 1.0f, "positive SDR white has a one-nit safety minimum");
		Check(NriHdrSafePeak(240.0f, 0.1f) == 1.0f, "positive peak remains authoritative with safety minimum");
		Check(NriHdrSafePeak(240.0f, 237.3f) == 237.3f, "valid peak below SDR white is not promoted");
		for (float invalid : { -inf, nan, inf })
		{
			Check(NriHdrScenePaperWhite(invalid, 240.0f, 237.3f) == 80.0f, "nonfinite scene white falls back to 80 nits");
			Check(NriHdrScenePaperWhite(invalid, 240.0f, 40.0f) == 40.0f, "fallback scene white remains peak bounded");
		}
		Check(NriHdrScenePaperWhite(0.0f, 240.0f, 237.3f) == 1.0f, "finite nonpositive scene white has safety minimum");
		Check(NriHdrScenePaperWhite(-4.0f, 240.0f, 237.3f) == 1.0f, "negative scene white has safety minimum");

		for (float sdr : { 80.0f, 120.0f, 240.0f, 400.0f })
		for (float peak : { 40.0f, 80.0f, 237.3f, 400.0f, 1000.0f })
		for (float requested : { 80.0f, 120.0f, 200.0f, 300.0f, 400.0f })
		{
			NRIPTOutputPolicy policy;
			policy.displaySdrLuminance = sdr;
			policy.displayMaxLuminance = peak;
			policy.paperWhiteNits = requested;
			const float expectedWhite = std::min(requested, peak);
			const float legacyUiWhite = std::clamp(std::max(requested, sdr), sdr, std::max(peak, sdr));
			Check(NriHdrScenePaperWhite(requested, sdr, peak) == expectedWhite, "scene white is independent of valid SDR white");
			Check(GetNRIPTOutputSafeDisplaySdrLuminance(sdr) == NriHdrSafeSdrWhite(sdr), "CPU SDR helper uses shared policy");
			Check(GetNRIPTOutputSafeDisplayMaxLuminance(sdr, peak) == NriHdrSafePeak(sdr, peak), "CPU peak helper uses shared policy");
			Check(GetNRIPTOutputClampedPaperWhiteNits(requested, sdr, peak) == expectedWhite, "CPU scene white helper uses shared policy");
			Check(Near(GetNRIPTHdrPaperWhiteScale(policy), expectedWhite / 80.0f), "scene white keeps scRGB 80-nit units");
			Check(Near(GetNRIPTHdrHeadroomInPaperWhites(policy), peak / expectedWhite), "CPU headroom uses authoritative peak");
			Check(Near(GetNRIPTHdrMaxOutputScale(policy), peak / 80.0f), "CPU maximum output matches authoritative peak");
			Check(Near(GetNRIPTHdrUiWhiteScale(policy), legacyUiWhite / 80.0f), "UI white exactly preserves legacy finite metadata policy");
		}
	}

	void CheckTonemapCurves()
	{
		static_assert(static_cast<unsigned int>(NRIPTTonemapMode::Hable) == 0u, "Hable scalar mode contract");
		static_assert(static_cast<unsigned int>(NRIPTTonemapMode::ACESFitted) == 1u, "ACES scalar mode contract");
		static_assert(static_cast<unsigned int>(NRIPTTonemapMode::Reinhard) == 2u, "Reinhard scalar mode contract");
		const float nan = std::numeric_limits<float>::quiet_NaN();
		const float inf = std::numeric_limits<float>::infinity();
		for (unsigned int mode = 0; mode < 3; ++mode)
		{
			for (float invalid : { -inf, -10.0f, 0.0f, nan })
				Check(NriHdrTonemapChannel(invalid, mode) == 0.0f, "invalid or nonpositive curve input produces black");
			Check(NriHdrTonemapChannel(inf, mode) == 1.0f, "positive infinite radiance approaches normalized peak");
			for (float huge : { 1.0e5f, 1.0e10f, 1.0e20f, std::numeric_limits<float>::max() })
			{
				const float value = NriHdrTonemapChannel(huge, mode);
				Check(std::isfinite(value) && value >= 0.9999f && value <= 1.0f, "large finite input avoids polynomial overflow");
			}
			float previous = 0.0f;
			for (unsigned int step = 1; step <= 1024; ++step)
			{
				const float input = static_cast<float>(step) / 16.0f;
				const float value = NriHdrTonemapChannel(input, mode);
				Check(std::isfinite(value) && value > previous && value < 1.0f, "HDR curve remains increasing without finite-white plateau");
				Check(Near(value, ReferenceTonemap(input, mode)), "shared tone map matches independent double-precision reference");
				previous = value;
			}
			Check(NriHdrTonemapChannel(0.9999f, mode) < NriHdrTonemapChannel(1.0f, mode), "curve increases into reciprocal-branch boundary");
			Check(NriHdrTonemapChannel(1.0f, mode) < NriHdrTonemapChannel(1.0001f, mode), "curve increases out of reciprocal-branch boundary");
		}
	}

	void CheckOutputRamps()
	{
		const std::array<float, 12> ramp = { 0.0f, 0.02f, 0.18f, 0.5f, 0.8f, 1.0f, 1.2f, 2.0f, 4.0f, 10.0f, 16.0f, 64.0f };
		for (unsigned int mode = 0; mode < 3; ++mode)
		for (float sdr : { 80.0f, 240.0f })
		for (float peak : { 80.0f, 237.3f, 400.0f, 1000.0f })
		for (float requested : { 80.0f, 120.0f, 200.0f, 300.0f, 400.0f })
		for (const auto& grading : { std::array<float, 2>{ 1.0f, 1.0f }, std::array<float, 2>{ 1.1f, 0.84375f },
			std::array<float, 2>{ 0.915625f, 0.521875f } })
		{
			NRIPTOutputPolicy policy;
			policy.displaySdrLuminance = sdr;
			policy.displayMaxLuminance = peak;
			policy.paperWhiteNits = requested;
			float previous = -1.0f;
			for (float input : ramp)
			{
				const float output = Output(input, mode, policy, grading[0], grading[1]);
				Check(std::isfinite(output) && output >= 0.0f && output < peak / 80.0f, "graded HDR ramp remains finite and below peak");
				Check(output > previous, "graded HDR ramp retains highlight separation including old 1..4 clipping range");
				previous = output;
			}
		}
		for (unsigned int mode = 0; mode < 3; ++mode)
		{
			NRIPTOutputPolicy policy;
			policy.displaySdrLuminance = 240.0f;
			policy.displayMaxLuminance = 237.3f;
			policy.paperWhiteNits = 120.0f;
			const float lowWhite = Output(1.2f, mode, policy);
			policy.paperWhiteNits = 200.0f;
			const float highWhite = Output(1.2f, mode, policy);
			Check(highWhite > lowWhite, "paper-white changes below valid peak now affect image brightness");
			policy.displaySdrLuminance = 80.0f;
			Check(Output(1.2f, mode, policy) == highWhite, "Windows SDR white does not alter native HDR scene output");
		}
		NRIPTOutputPolicy lowPeak;
		lowPeak.displaySdrLuminance = 240.0f;
		lowPeak.displayMaxLuminance = 237.3f;
		lowPeak.paperWhiteNits = 300.0f;
		for (float input : { 1.0f, 2.0f, 4.0f })
		{
			const float oldNits = Clamp01(2.0f * input / (1.0f + input)) * 240.0f;
			const float newNits = Output(input, 2u, lowPeak) * 80.0f;
			Check(oldNits == 240.0f, "fixture reproduces old early-clipping plateau");
			Check(Near(newNits, 237.3f * input / (1.0f + input)), "new headroom-one Reinhard has a smooth bounded closed form");
			std::cout << "HDR neutral ramp: input=" << input << " old_nits=" << oldNits << " new_nits=" << newNits << '\n';
		}
	}

	float Luma(const std::array<float, 3>& color)
	{
		return color[0] * 0.2126f + color[1] * 0.7152f + color[2] * 0.0722f;
	}

	void CheckChromaBounds()
	{
		const float nan = std::numeric_limits<float>::quiet_NaN();
		const float inf = std::numeric_limits<float>::infinity();
		for (float invalid : { -inf, nan, inf })
			Check(NriHdrSaturationScale(0.5f, 0.25f, 0.75f, invalid) == 0.0f, "nonfinite saturation uses finite zero-chroma fallback");
		const std::array<std::array<float, 3>, 8> colors = {{
			{ 0.0f, 0.0f, 0.0f }, { 1.0f, 1.0f, 1.0f }, { 0.5f, 0.5f, 0.5f },
			{ 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f }, { 0.0f, 0.0f, 1.0f },
			{ 0.99f, 0.80f, 0.60f }, { 0.02f, 0.06f, 0.35f }
		}};
		auto validate = [](const std::array<float, 3>& color, float requested)
		{
			const float luma = Luma(color);
			const float lo = *std::min_element(color.begin(), color.end());
			const float hi = *std::max_element(color.begin(), color.end());
			const float scale = NriHdrSaturationScale(luma, lo, hi, requested);
			Check(std::isfinite(scale) && scale >= 0.0f && scale <= std::max(requested, 0.0f), "gamut scale is finite and never increases requested saturation");
			std::array<float, 3> result = {};
			for (unsigned int channel = 0; channel < 3; ++channel)
			{
				result[channel] = luma + (color[channel] - luma) * scale;
				Check(result[channel] >= -2.0e-6f && result[channel] <= 1.0f + 2.0e-6f, "gamut-limited colored channel stays inside display range");
			}
			Check(Near(Luma(result), luma, 2.0e-6f), "gamut-limited saturation preserves luminance instead of clipping it");
			if (requested == 1.0f)
				for (unsigned int channel = 0; channel < 3; ++channel)
					Check(Near(result[channel], color[channel], 2.0e-6f), "neutral saturation preserves in-gamut color");
		};
		for (const auto& color : colors)
		for (float saturation : { -1.0f, 0.0f, 0.5f, 1.0f, 1.75f, 2.0f })
			validate(color, saturation);
		for (unsigned int mode = 0; mode < 3; ++mode)
		for (float intensity : { 0.02f, 0.18f, 0.5f, 1.0f, 2.0f, 4.0f, 16.0f, 64.0f })
		for (const auto& tint : { std::array<float, 3>{ 1.0f, 0.8f, 0.5f }, std::array<float, 3>{ 0.2f, 0.6f, 1.0f } })
		for (float saturation : { 1.0f, 1.75f, 2.0f })
		for (const auto& grading : { std::array<float, 2>{ 1.1f, 0.84375f }, std::array<float, 2>{ 0.915625f, 0.521875f } })
		{
			std::array<float, 3> color = {};
			for (unsigned int channel = 0; channel < 3; ++channel)
				color[channel] = Grade(NriHdrTonemapChannel(intensity * tint[channel], mode), grading[0], grading[1]);
			validate(color, saturation);
		}
	}
}

int main()
{
	CheckMetadataAndCpuPolicy();
	CheckTonemapCurves();
	CheckOutputRamps();
	CheckChromaBounds();
	std::cout << "HDR output math tests passed: " << checks << " checks (production C++/HLSL shared math).\n";
	return 0;
}
