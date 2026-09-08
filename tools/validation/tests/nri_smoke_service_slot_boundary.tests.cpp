#include <cstdint>
#include <iostream>
#include <limits>

class NRIPassDispatchContext
{
public:
	enum class FrameTextureSlot : uint32_t
	{
		First = 0u,
		Count = 53u
	};

	struct SmokeService
	{
		using GetVolumeSlotFn = uint32_t (*)(void* user, bool metadata);

		void* user = nullptr;
		GetVolumeSlotFn getVolumeSlot = nullptr;

		FrameTextureSlot GetVolumeSlot(bool metadata) const;
	};
};

// ACTUAL_GET_VOLUME_SLOT_IMPLEMENTATION

namespace
{
	struct CallbackState
	{
		uint32_t result = 0u;
		uint32_t calls = 0u;
		bool metadata = false;
	};

	uint32_t ReturnConfiguredSlot(void* user, bool metadata)
	{
		auto& state = *static_cast<CallbackState*>(user);
		++state.calls;
		state.metadata = metadata;
		return state.result;
	}

	bool Expect(const char* name, uint32_t rawSlot, bool metadata,
		NRIPassDispatchContext::FrameTextureSlot expected)
	{
		CallbackState state = {};
		state.result = rawSlot;
		NRIPassDispatchContext::SmokeService service = {};
		service.user = &state;
		service.getVolumeSlot = &ReturnConfiguredSlot;
		const auto observed = service.GetVolumeSlot(metadata);
		if (observed != expected || state.calls != 1u || state.metadata != metadata)
		{
			std::cerr << name << " failed: raw=" << rawSlot
				<< " observed=" << static_cast<uint32_t>(observed)
				<< " expected=" << static_cast<uint32_t>(expected)
				<< " calls=" << state.calls
				<< " metadata=" << state.metadata << '\n';
			return false;
		}
		return true;
	}
}

int main()
{
	using Slot = NRIPassDispatchContext::FrameTextureSlot;
	constexpr uint32_t count = static_cast<uint32_t>(Slot::Count);

	NRIPassDispatchContext::SmokeService nullService = {};
	if (nullService.GetVolumeSlot(true) != Slot::Count)
	{
		std::cerr << "null callback did not return Count\n";
		return 1;
	}

	if (!Expect("first", 0u, false, Slot::First) ||
		!Expect("last", count - 1u, true, static_cast<Slot>(count - 1u)) ||
		!Expect("Count", count, false, Slot::Count) ||
		!Expect("Count+1", count + 1u, true, Slot::Count) ||
		!Expect("UINT32_MAX", std::numeric_limits<uint32_t>::max(), false, Slot::Count))
	{
		return 1;
	}

	std::cout << "SmokeService volume-slot boundary tests passed.\n";
	return 0;
}
