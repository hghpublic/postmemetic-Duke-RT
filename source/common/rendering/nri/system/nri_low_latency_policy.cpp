#include "nri_low_latency_policy.h"

#include "nri_low_latency_contract.h"
#include "nri_renderdevice.h"
#include "../renderer/nri_cvars.h"

#include <chrono>
#include <cstring>

bool NRILowLatencyPolicy::ShouldRequestSwapChain(const NRIRenderDevice& frameBuffer) const
{
	nri_low_latency_contract::SwapChainRequest request = {};
	request.nativeRequested = !!nri_lowlatency;
	request.frameGenerationRequested = !!nri_framegen && !!nri_framegenlatency;
	request.d3d12 = frameBuffer.GetLiveAPI() == nri::GraphicsAPI::D3D12;
	request.deviceAvailable = frameBuffer.mDevice != nullptr;
	request.swapChainInterfaceAvailable = frameBuffer.mSwapChainInterface.CreateSwapChain != nullptr;
	request.interfaceComplete =
		frameBuffer.mLowLatency.SetLatencySleepMode != nullptr &&
		frameBuffer.mLowLatency.SetLatencyMarker != nullptr &&
		frameBuffer.mLowLatency.LatencySleep != nullptr &&
		frameBuffer.mLowLatency.GetLatencyReport != nullptr;
	if (frameBuffer.mDevice != nullptr)
	{
		request.featureAvailable = !!frameBuffer.mCore.GetDeviceDesc(*frameBuffer.mDevice).features.lowLatency;
	}
	return nri_low_latency_contract::ShouldRequestSwapChain(request);
}

void NRILowLatencyPolicy::OnSwapChainCreated(const NRIRenderDevice& frameBuffer)
{
	RefreshAvailability(frameBuffer);
	ConfigureSleepMode(frameBuffer);
}

void NRILowLatencyPolicy::OnSwapChainDestroyed(const NRIRenderDevice& frameBuffer)
{
	if (mState.presentationGeneration != 0 && !mState.contractValid &&
		(mState.sleepOrder != 0 || mState.simulationStartOrder != 0 || mState.renderSubmitStartOrder != 0))
	{
		++mState.abortedTransactionCount;
		mState.lastAbortReason = "swapchain-destroy";
	}
	if (mState.sleepModeConfigured && frameBuffer.mSwapChain != nullptr &&
		frameBuffer.mLowLatency.SetLatencySleepMode != nullptr)
	{
		nri::LatencySleepMode disabledMode = {};
		frameBuffer.mLowLatency.SetLatencySleepMode(*frameBuffer.mSwapChain, disabledMode);
	}
	const uint64_t sleepCount = mState.latencySleepCount;
	const uint64_t markerCount = mState.markerCount;
	const uint64_t completeCount = mState.completeContractCount;
	const uint64_t duplicateCount = mState.duplicateInputSampleCount;
	const uint64_t abortedCount = mState.abortedTransactionCount;
	const char* lastAbortReason = mState.lastAbortReason;
	mState = {};
	mState.latencySleepCount = sleepCount;
	mState.markerCount = markerCount;
	mState.completeContractCount = completeCount;
	mState.duplicateInputSampleCount = duplicateCount;
	mState.abortedTransactionCount = abortedCount;
	mState.lastAbortReason = lastAbortReason;
	mLastLatencyReport = {};
	mHasLastLatencyReport = false;
}

void NRILowLatencyPolicy::BeginSimulation(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration)
{
	if (mState.presentationGeneration != 0 && !mState.contractValid &&
		(mState.sleepOrder != 0 || mState.simulationStartOrder != 0 || mState.renderSubmitStartOrder != 0))
	{
		++mState.abortedTransactionCount;
		mState.lastAbortReason = "presentation-rollover";
	}
	ResetFrameState(presentationGeneration);
	RefreshAvailability(frameBuffer);
}

void NRILowLatencyPolicy::MarkInputSample(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration)
{
	if (presentationGeneration != mState.presentationGeneration || !IsOperational(frameBuffer))
	{
		return;
	}
	if (mState.inputSampleMarked)
	{
		++mState.duplicateInputSampleCount;
		return;
	}
	if (!mState.sleepModeConfigured)
	{
		ConfigureSleepMode(frameBuffer);
	}
	if (!mState.sleepModeConfigured)
	{
		return;
	}

	const auto sleepStart = std::chrono::steady_clock::now();
	mState.latencySleepResult = frameBuffer.mLowLatency.LatencySleep(*frameBuffer.mSwapChain);
	const auto sleepEnd = std::chrono::steady_clock::now();
	mState.latencySleepUs = (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(sleepEnd - sleepStart).count();
	if (mState.latencySleepResult != nri::Result::SUCCESS)
	{
		SuppressRuntime(frameBuffer, "sleep");
		return;
	}
	mState.sleepInvoked = true;
	mState.sleepOrder = ++mState.sequence;
	++mState.latencySleepCount;
	SetMarker(
		frameBuffer,
		nri::LatencyMarker::SIMULATION_START,
		mState.simulationStartMarkerResult,
		mState.simulationStartOrder,
		"simulation-start");
	mState.simulationActive = mState.simulationStartMarkerResult == nri::Result::SUCCESS;
	if (!mState.simulationActive)
	{
		return;
	}

	SetMarker(
		frameBuffer,
		nri::LatencyMarker::INPUT_SAMPLE,
		mState.inputSampleMarkerResult,
		mState.inputSampleOrder,
		"input-sample");
	mState.inputSampleMarked = mState.inputSampleMarkerResult == nri::Result::SUCCESS;
}

void NRILowLatencyPolicy::EndSimulation(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration)
{
	if (!mState.simulationActive || presentationGeneration != mState.presentationGeneration)
	{
		return;
	}
	SetMarker(
		frameBuffer,
		nri::LatencyMarker::SIMULATION_END,
		mState.simulationEndMarkerResult,
		mState.simulationEndOrder,
		"simulation-end");
	mState.simulationActive = false;
	UpdateContractValidity();
}

void NRILowLatencyPolicy::OnRenderSubmitStart(const NRIRenderDevice& frameBuffer, bool submitAssociated)
{
	mState.submitAssociated = submitAssociated;
	if (!HasCompleteSimulationPrefix() || !mState.submitAssociated)
	{
		return;
	}
	SetMarker(
		frameBuffer,
		nri::LatencyMarker::RENDER_SUBMIT_START,
		mState.renderSubmitStartMarkerResult,
		mState.renderSubmitStartOrder,
		"render-submit-start");
}

void NRILowLatencyPolicy::OnRenderSubmitEnd(const NRIRenderDevice& frameBuffer, nri::Result submitResult)
{
	if (mState.renderSubmitStartOrder == 0)
	{
		return;
	}
	SetMarker(
		frameBuffer,
		nri::LatencyMarker::RENDER_SUBMIT_END,
		mState.renderSubmitEndMarkerResult,
		mState.renderSubmitEndOrder,
		"render-submit-end");
	mState.submitSucceeded = submitResult == nri::Result::SUCCESS;
	UpdateContractValidity();
}

void NRILowLatencyPolicy::OnPresentStart(const NRIRenderDevice& frameBuffer)
{
	if (!IsOperational(frameBuffer) || !mState.submitSucceeded || mState.renderSubmitEndOrder == 0)
	{
		return;
	}
	mState.presentBoundarySeen = true;
	mState.presentStartOrder = ++mState.sequence;
}

void NRILowLatencyPolicy::OnPresentEnd(const NRIRenderDevice& frameBuffer, nri::Result presentResult)
{
	if (!IsOperational(frameBuffer) || !mState.submitSucceeded || mState.presentStartOrder == 0 ||
		presentResult != nri::Result::SUCCESS)
	{
		return;
	}
	mState.presentBoundarySeen = true;
	mState.presentSucceeded = true;
	mState.presentEndOrder = ++mState.sequence;
	mState.latencyReportResult = frameBuffer.mLowLatency.GetLatencyReport(*frameBuffer.mSwapChain, mState.latencyReport);
	if (mState.latencyReportResult == nri::Result::SUCCESS)
	{
		mState.reportChanged = !mHasLastLatencyReport ||
			std::memcmp(&mState.latencyReport, &mLastLatencyReport, sizeof(mLastLatencyReport)) != 0;
		mState.reportAllZero =
			mState.latencyReport.inputSampleTimeUs == 0 &&
			mState.latencyReport.simulationStartTimeUs == 0 &&
			mState.latencyReport.simulationEndTimeUs == 0 &&
			mState.latencyReport.renderSubmitStartTimeUs == 0 &&
			mState.latencyReport.renderSubmitEndTimeUs == 0 &&
			mState.latencyReport.presentStartTimeUs == 0 &&
			mState.latencyReport.presentEndTimeUs == 0 &&
			mState.latencyReport.driverStartTimeUs == 0 &&
			mState.latencyReport.driverEndTimeUs == 0 &&
			mState.latencyReport.osRenderQueueStartTimeUs == 0 &&
			mState.latencyReport.osRenderQueueEndTimeUs == 0 &&
			mState.latencyReport.gpuRenderStartTimeUs == 0 &&
			mState.latencyReport.gpuRenderEndTimeUs == 0;
		mLastLatencyReport = mState.latencyReport;
		mHasLastLatencyReport = true;
	}
	const bool wasValid = mState.contractValid;
	UpdateContractValidity();
	if (!wasValid && mState.contractValid)
	{
		++mState.completeContractCount;
	}
}

bool NRILowLatencyPolicy::IsOperational(const NRIRenderDevice& frameBuffer) const
{
	return
		mState.operational &&
		frameBuffer.mSwapChain != nullptr &&
		!frameBuffer.IsFrameGenerationPresentPathActive();
}

void NRILowLatencyPolicy::RefreshAvailability(const NRIRenderDevice& frameBuffer)
{
	mState.requested = !!nri_lowlatency || (!!nri_framegen && !!nri_framegenlatency);
	mState.interfaceAvailable =
		frameBuffer.mLowLatency.SetLatencySleepMode != nullptr &&
		frameBuffer.mLowLatency.SetLatencyMarker != nullptr &&
		frameBuffer.mLowLatency.LatencySleep != nullptr &&
		frameBuffer.mLowLatency.GetLatencyReport != nullptr;
	mState.featureAvailable = false;
	if (frameBuffer.mDevice != nullptr)
	{
		mState.featureAvailable = !!frameBuffer.mCore.GetDeviceDesc(*frameBuffer.mDevice).features.lowLatency;
	}
	mState.swapChainEnabled =
		frameBuffer.mSwapChain != nullptr &&
		(((uint32_t)frameBuffer.mSwapChainFlags & (uint32_t)nri::SwapChainBits::ALLOW_LOW_LATENCY) != 0);
	mState.operational =
		mState.requested &&
		frameBuffer.GetLiveAPI() == nri::GraphicsAPI::D3D12 &&
		mState.interfaceAvailable &&
		mState.featureAvailable &&
		mState.swapChainEnabled &&
		!mState.runtimeSuppressed &&
		!frameBuffer.IsFrameGenerationPresentPathActive();
}

void NRILowLatencyPolicy::ConfigureSleepMode(const NRIRenderDevice& frameBuffer)
{
	mState.sleepModeConfigured = false;
	mState.setSleepModeResult = nri::Result::FAILURE;
	if (!IsOperational(frameBuffer))
	{
		return;
	}

	mState.configuredSleepMode = {};
	mState.configuredSleepMode.minIntervalUs = 0;
	mState.configuredSleepMode.lowLatencyMode = true;
	mState.configuredSleepMode.lowLatencyBoost = false;
	mState.setSleepModeResult = frameBuffer.mLowLatency.SetLatencySleepMode(
		*frameBuffer.mSwapChain,
		mState.configuredSleepMode);
	mState.sleepModeConfigured = mState.setSleepModeResult == nri::Result::SUCCESS;
	if (!mState.sleepModeConfigured)
	{
		SuppressRuntime(frameBuffer, "set-mode");
	}
}

void NRILowLatencyPolicy::SetMarker(
	const NRIRenderDevice& frameBuffer,
	nri::LatencyMarker marker,
	nri::Result& result,
	uint64_t& order,
	const char* failureStage)
{
	result = nri::Result::FAILURE;
	if (!IsOperational(frameBuffer) || order != 0)
	{
		return;
	}
	result = frameBuffer.mLowLatency.SetLatencyMarker(*frameBuffer.mSwapChain, marker);
	if (result == nri::Result::SUCCESS)
	{
		order = ++mState.sequence;
		++mState.markerCount;
	}
	else
	{
		SuppressRuntime(frameBuffer, failureStage);
	}
}

void NRILowLatencyPolicy::SuppressRuntime(const NRIRenderDevice& frameBuffer, const char* failureStage)
{
	if (mState.sleepModeConfigured && frameBuffer.mSwapChain != nullptr &&
		frameBuffer.mLowLatency.SetLatencySleepMode != nullptr)
	{
		nri::LatencySleepMode disabledMode = {};
		mState.runtimeDisableResult = frameBuffer.mLowLatency.SetLatencySleepMode(
			*frameBuffer.mSwapChain,
			disabledMode);
		mState.sleepModeConfigured = false;
	}
	mState.runtimeSuppressed = true;
	mState.runtimeFailure = failureStage;
	mState.operational = false;
}

void NRILowLatencyPolicy::ResetFrameState(uint64_t presentationGeneration)
{
	const bool requested = mState.requested;
	const bool interfaceAvailable = mState.interfaceAvailable;
	const bool featureAvailable = mState.featureAvailable;
	const bool swapChainEnabled = mState.swapChainEnabled;
	const bool sleepModeConfigured = mState.sleepModeConfigured;
	const nri::LatencySleepMode configuredSleepMode = mState.configuredSleepMode;
	const nri::Result setSleepModeResult = mState.setSleepModeResult;
	const uint64_t sleepCount = mState.latencySleepCount;
	const uint64_t markerCount = mState.markerCount;
	const uint64_t completeCount = mState.completeContractCount;
	const uint64_t duplicateCount = mState.duplicateInputSampleCount;
	const uint64_t abortedCount = mState.abortedTransactionCount;
	const bool runtimeSuppressed = mState.runtimeSuppressed;
	const char* runtimeFailure = mState.runtimeFailure;
	const char* lastAbortReason = mState.lastAbortReason;
	const nri::Result runtimeDisableResult = mState.runtimeDisableResult;
	mState = {};
	mState.requested = requested;
	mState.interfaceAvailable = interfaceAvailable;
	mState.featureAvailable = featureAvailable;
	mState.swapChainEnabled = swapChainEnabled;
	mState.sleepModeConfigured = sleepModeConfigured;
	mState.configuredSleepMode = configuredSleepMode;
	mState.setSleepModeResult = setSleepModeResult;
	mState.presentationGeneration = presentationGeneration;
	mState.latencySleepCount = sleepCount;
	mState.markerCount = markerCount;
	mState.completeContractCount = completeCount;
	mState.duplicateInputSampleCount = duplicateCount;
	mState.abortedTransactionCount = abortedCount;
	mState.runtimeSuppressed = runtimeSuppressed;
	mState.runtimeFailure = runtimeFailure;
	mState.lastAbortReason = lastAbortReason;
	mState.runtimeDisableResult = runtimeDisableResult;
}

void NRILowLatencyPolicy::UpdateContractValidity()
{
	nri_low_latency_contract::Sequence sequence = {};
	sequence.sleep = mState.sleepOrder;
	sequence.simulationStart = mState.simulationStartOrder;
	sequence.inputSample = mState.inputSampleOrder;
	sequence.simulationEnd = mState.simulationEndOrder;
	sequence.renderSubmitStart = mState.renderSubmitStartOrder;
	sequence.renderSubmitEnd = mState.renderSubmitEndOrder;
	sequence.presentStart = mState.presentStartOrder;
	sequence.presentEnd = mState.presentEndOrder;
	mState.contractValid =
		mState.submitSucceeded &&
		mState.presentSucceeded &&
		nri_low_latency_contract::IsCompleteAndOrdered(sequence);
}

bool NRILowLatencyPolicy::HasCompleteSimulationPrefix() const
{
	return
		mState.sleepOrder != 0 &&
		mState.sleepOrder < mState.simulationStartOrder &&
		mState.simulationStartOrder < mState.inputSampleOrder &&
		mState.inputSampleOrder < mState.simulationEndOrder;
}
