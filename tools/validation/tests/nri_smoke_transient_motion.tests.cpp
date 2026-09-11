#include "nri_smoke_transient_motion.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>

namespace
{
unsigned checks = 0;
void Check(bool condition, const char* message)
{
	++checks;
	if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
NRISmokeTransientLobeGpu Lobe(uint32_t seed)
{
	NRISmokeTransientLobeGpu lobe;
	lobe.position[0] = static_cast<float>(seed);
	lobe.radius = 10.0f;
	lobe.flags = 1u;
	lobe.densityScale = 0.5f;
	lobe.groupSlot = 3u;
	lobe.groupGeneration = 7u;
	lobe.epoch = 2u;
	lobe.deterministicSeed = seed;
	return lobe;
}
}

int main()
{
	NRISmokeTransientMotion motion;
	std::vector<NRISmokeTransientLobeGpu> lobes = { Lobe(1), Lobe(2) };
	Check(motion.Prepare(10, lobes)[0].radius == 0.0f, "first frame has no history");
	motion.Commit();
	lobes[0].position[0] += 3.0f;
	lobes[0].radius = 12.0f;
	std::reverse(lobes.begin(), lobes.end());
	auto previous = motion.Prepare(11, lobes);
	Check(previous[1].position[0] == 1.0f && previous[1].radius == 10.0f,
		"reordered logical lobe retains previous translation and radius");
	const float currentPoint = lobes[1].position[0] + 6.0f;
	const float previousPoint = previous[1].position[0] +
		(currentPoint - lobes[1].position[0]) * previous[1].radius / lobes[1].radius;
	Check(std::abs(previousPoint - 6.0f) < 1e-6f, "growth maps the same normalized interior point");
	// A failed upload is not committed. Retrying must still use frame 10.
	Check(motion.Prepare(11, lobes)[1].radius == 10.0f, "prepare does not publish uncommitted transforms");
	motion.Commit();
	Check(motion.Prepare(13, lobes)[0].radius == 0.0f, "skipped rendered frame rejects history");
	motion.Commit();
	Check(motion.Prepare(14, lobes, true)[0].radius == 0.0f, "camera cut/reset rejects history");
	motion.Commit();
	Check(motion.Prepare(15, lobes)[0].radius > 0.0f, "history restarts after reset frame");
	motion.Commit();
	Check(motion.Prepare(16, {}).empty(), "empty snapshot is accepted");
	motion.Commit();
	Check(motion.Prepare(17, lobes)[0].radius == 0.0f, "reentry after empty frame cannot reuse old smoke");
	motion.Commit();
	lobes[0].groupGeneration++;
	Check(motion.Prepare(18, lobes)[0].radius == 0.0f, "recycled group slot rejects prior generation");
	Check(motion.Prepare(18, lobes)[1].radius > 0.0f, "unrelated live group still tracks");
	motion.Commit();
	lobes[0].epoch++;
	Check(motion.Prepare(19, lobes)[0].radius == 0.0f, "epoch change rejects identity");
	motion.Commit();
	lobes[0].styleIndex++;
	Check(motion.Prepare(20, lobes)[0].radius == 0.0f, "style replacement rejects identity");
	motion.Commit();
	lobes[0].transientClass++;
	Check(motion.Prepare(21, lobes)[0].radius == 0.0f, "class replacement rejects identity");
	motion.Commit();

	for (int invalidCase = 0; invalidCase < 6; ++invalidCase)
	{
		motion.Reset(); lobes = { Lobe(1) };
		motion.Prepare(0, lobes); motion.Commit();
		switch (invalidCase)
		{
		case 0: lobes[0].flags = 0; break;
		case 1: lobes[0].shape = 1; break;
		case 2: lobes[0].densityScale = 0; break;
		case 3: lobes[0].radius = 0; break;
		case 4: lobes[0].position[1] = std::numeric_limits<float>::quiet_NaN(); break;
		case 5: lobes[0].radius = std::numeric_limits<float>::infinity(); break;
		}
		Check(motion.Prepare(1, lobes)[0].radius == 0, "invalid current input rejects history");
		motion.Commit(); lobes = { Lobe(1) };
		Check(motion.Prepare(2, lobes)[0].radius == 0, "invalid previous input rejects history");
	}
	motion.Reset(); lobes = { Lobe(1), Lobe(1) };
	motion.Prepare(0, lobes); motion.Commit();
	Check(motion.Prepare(1, { Lobe(1) })[0].radius == 0, "duplicate prior seeds are ambiguous");
	motion.Commit();
	previous = motion.Prepare(2, lobes);
	Check(previous[0].radius == 0 && previous[1].radius == 0, "duplicate current seeds are ambiguous");
	motion.Reset();
	lobes.clear();
	for (uint32_t seed = 0; seed < 256; ++seed) lobes.push_back(Lobe(seed));
	motion.Prepare(100, lobes); motion.Commit();
	for (uint32_t frame = 101; frame < 141; ++frame)
	{
		std::rotate(lobes.begin(), lobes.begin() + 19, lobes.end());
		for (auto& lobe : lobes) { lobe.position[2] += 0.25f; lobe.radius += 0.125f; }
		previous = motion.Prepare(frame, lobes);
		for (size_t i = 0; i < lobes.size(); ++i)
			Check(previous[i].position[0] == lobes[i].position[0] &&
				previous[i].position[2] == lobes[i].position[2] - 0.25f &&
				previous[i].radius == lobes[i].radius - 0.125f, "full-capacity compaction tracks exact prior transforms");
		motion.Commit();
	}
	std::printf("%u transient motion checks passed.\n", checks);
}
