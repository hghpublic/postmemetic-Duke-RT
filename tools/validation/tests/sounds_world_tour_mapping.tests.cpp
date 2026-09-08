#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace
{
	struct Sound
	{
		int resourceId = 0;
		int lump = 0;
		int worldTourMapping = -1;
		std::string name;
		std::string payload;
	};

	class ForcedRelocatingSounds
	{
	public:
		ForcedRelocatingSounds()
		{
			mSounds.reserve(2u);
			mSounds.push_back({ 0, 0, -1, "sentinel", "unused" });
			mSounds.push_back({ 42, 17, -1, "world-tour.ogg", "source-payload" });
		}

		Sound* GetSfx(size_t index) { return &mSounds.at(index); }

		Sound* AllocateSound()
		{
			// The capacity is exactly the pre-allocation size, so this append must
			// relocate the contiguous storage just as a growing TArray may do.
			mSounds.emplace_back();
			return &mSounds.back();
		}

		size_t Size() const { return mSounds.size(); }

	private:
		std::vector<Sound> mSounds;
	};

	bool TestReacquisitionAfterForcedRelocation()
	{
		ForcedRelocatingSounds sounds;
		constexpr size_t sourceId = 1u;
		Sound* source = sounds.GetSfx(sourceId);
		const uintptr_t addressBeforeAllocation = reinterpret_cast<uintptr_t>(source);

		Sound* replacement = sounds.AllocateSound();
		source = sounds.GetSfx(sourceId);
		if (addressBeforeAllocation == reinterpret_cast<uintptr_t>(source))
		{
			std::cerr << "test setup did not force contiguous-storage relocation\n";
			return false;
		}

		// This is the production ordering under test: reacquire by stable ID,
		// then copy, specialize the replacement, and write the source mapping.
		*replacement = *source;
		replacement->resourceId = -1;
		replacement->name = "original.voc";
		replacement->lump = 99;
		source->worldTourMapping = static_cast<int>(sounds.Size() - 1u);

		if (replacement->payload != "source-payload" ||
			replacement->resourceId != -1 || replacement->name != "original.voc" ||
			replacement->lump != 99 || source->worldTourMapping != 2)
		{
			std::cerr << "reacquired source copy/back-mapping contract failed\n";
			return false;
		}
		return true;
	}
}

int main()
{
	if (!TestReacquisitionAfterForcedRelocation())
		return 1;
	std::cout << "World Tour sound forced-relocation model passed.\n";
	return 0;
}
