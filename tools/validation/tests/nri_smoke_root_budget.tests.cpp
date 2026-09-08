#include "nri_smoke_contracts.h"

#include "NRI.h"
#include "Extensions/NRIHelper.h"

#include <cstdlib>
#include <iostream>

namespace
{
void Require(bool condition, const char* message)
{
	if (!condition)
	{
		std::cerr << "FAILED: " << message << '\n';
		std::exit(1);
	}
}

nri::PipelineLayoutSettingsDesc SmokeLayoutSettings(uint32_t rootConstantSize)
{
	nri::PipelineLayoutSettingsDesc settings = {};
	settings.descriptorSetNum = 6u;
	settings.descriptorRangeNum = 10u;
	settings.rootConstantSize = rootConstantSize;
	settings.rootDescriptorNum = 0u;
	settings.preferRootDescriptorsOverConstants = false;
	settings.enableD3D12DrawParametersEmulation = false;
	return settings;
}
}

int main()
{
	static_assert(sizeof(NRISmokeConstants) == 216u,
		"The production smoke root-constant contract must remain 216 bytes");

	nri::DeviceDesc deviceDesc = {};
	deviceDesc.graphicsAPI = nri::GraphicsAPI::D3D12;
	deviceDesc.pipelineLayout.descriptorSetMaxNum = 6u;
	deviceDesc.pipelineLayout.rootConstantMaxSize = 256u;
	deviceDesc.pipelineLayout.rootDescriptorMaxNum = 0u;

	const nri::PipelineLayoutSettingsDesc production =
		SmokeLayoutSettings(static_cast<uint32_t>(sizeof(NRISmokeConstants)));
	const nri::PipelineLayoutSettingsDesc fittedProduction =
		nri::FitPipelineLayoutSettingsIntoDeviceLimits(deviceDesc, production);

	Require(fittedProduction.descriptorSetNum == production.descriptorSetNum,
		"NRIHelper reduced the production smoke descriptor-set count");
	Require(fittedProduction.descriptorRangeNum == production.descriptorRangeNum,
		"NRIHelper reduced the production smoke descriptor-range count");
	Require(fittedProduction.rootConstantSize == production.rootConstantSize,
		"NRIHelper reduced the production 216-byte smoke root constants");
	Require(fittedProduction.rootDescriptorNum == production.rootDescriptorNum,
		"NRIHelper changed the production smoke root-descriptor count");
	Require(fittedProduction.preferRootDescriptorsOverConstants ==
		production.preferRootDescriptorsOverConstants,
		"NRIHelper changed the production smoke fitting preference");
	Require(fittedProduction.enableD3D12DrawParametersEmulation ==
		production.enableD3D12DrawParametersEmulation,
		"NRIHelper changed the production draw-parameters emulation setting");

	const nri::PipelineLayoutSettingsDesc regression = SmokeLayoutSettings(232u);
	const nri::PipelineLayoutSettingsDesc fittedRegression =
		nri::FitPipelineLayoutSettingsIntoDeviceLimits(deviceDesc, regression);
	Require(fittedRegression.rootConstantSize == sizeof(NRISmokeConstants),
		"NRIHelper did not clamp the 232-byte regression to the 216-byte D3D12 budget");
	Require(fittedRegression.rootConstantSize < regression.rootConstantSize,
		"The root-budget regression case unexpectedly fit without reduction");

	std::cout << "PASS: NRI smoke root budget (6 sets, 10 ranges, 216-byte constants; "
		"232-byte regression clamps to 216)\n";
	return 0;
}
