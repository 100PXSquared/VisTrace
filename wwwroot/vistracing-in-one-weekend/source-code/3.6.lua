----------------
-- Parameters --
----------------
local RESX, RESY = 256, 256
local SAMPLES = 8
local MAX_DEPTH = 8

local FOCAL_LENGTH_MM = 60
local SENSOR_HEIGHT_MM = 24

----------------
--    Init    --
----------------
local accel = vistrace.CreateAccel(ents.FindByClass("prop_*"), false)
local hdri = vistrace.LoadHDRI("drackenstein_quarry_4k")
local sampler = vistrace.CreateSampler()

local hdr = vistrace.CreateRenderTarget(RESX, RESY, VisTraceRTFormat.RGBFFF)

local sensorWidth = SENSOR_HEIGHT_MM * RESX / RESY

local halfSensorWidth = sensorWidth / 2
local halfSensorHeight = SENSOR_HEIGHT_MM / 2

local sensorWidthDivRes = sensorWidth / RESX
local sensorHeightDivRes = SENSOR_HEIGHT_MM / RESY

local camConeAngle = math.atan(SENSOR_HEIGHT_MM / FOCAL_LENGTH_MM / RESY)

local rt = GetRenderTargetEx(
	"VisTracer",                     -- Name of the render target
	1, 1, RT_SIZE_FULL_FRAME_BUFFER, -- Resize to screen res automatically
	MATERIAL_RT_DEPTH_SEPARATE,      -- Create a dedicated depth/stencil buffer
	bit.bor(1, 256),                 -- Texture flags for point sampling and no mips
	0,                               -- No RT flags
	IMAGE_FORMAT_RGBA8888            -- RGB image format with 8 bits per channel
)

local rtMat = CreateMaterial("VisTracer", "UnlitGeneric", {
	["$basetexture"] = rt:GetName(),
	["$translucent"] = "1" -- Enables transparency on the material
})

local function SampleLambert(result, r1, r2)
	local z = math.sqrt(r1)
	local sinTheta = math.sqrt(1 - r1)
	local phi = 2 * math.pi * r2

	return {
		scattered = (
			sinTheta * math.cos(phi) * result:Tangent() +
			sinTheta * math.sin(phi) * result:Binormal() +
			z                        * result:Normal()
		),
		weight    = result:Albedo(),
		pdf       = z / math.pi
	}
end

local function EvalLambert(result, scattered)
	local cosTheta = scattered:Dot(result:Normal())
	if cosTheta <= 0 then return Vector(0, 0, 0) end

	return result:Albedo() / math.pi * cosTheta
end

local function EvalLambertPDF(result, scattered)
	local cosTheta = scattered:Dot(result:Normal())
	if cosTheta <= 0 then return 0 end

	return cosTheta / math.pi
end

local function Power2Heuristic(p0, p1)
	local p02 = p0 * p0
	return p02 / (p02 + p1 * p1)
end

local camPos, camAng = LocalPlayer():EyePos(), LocalPlayer():EyeAngles()
local function TracePixel(x, y)
	local camX = halfSensorWidth - sensorWidthDivRes * (x + 0.5)
	local camY = halfSensorHeight - sensorHeightDivRes * (y + 0.5)

	local camDir = Vector(FOCAL_LENGTH_MM, camX, camY)
	camDir:Rotate(camAng)
	camDir:Normalize()

	local camRay = accel:Traverse(camPos, camDir, nil, nil, 0, camConeAngle)
	if camRay then
		local colour = Vector()

		local validSamples = SAMPLES
		for sample = 1, SAMPLES do
			local result = camRay
			local throughput = Vector(1, 1, 1)

			for depth = 1, MAX_DEPTH do
				local sample = SampleLambert(result, sampler:GetFloat2D())

				local origin = vistrace.CalcRayOrigin(result:Pos(), result:GeometricNormal())

				local envValid, envDir, envCol, envPdf = hdri:Sample(sampler)
				if envValid then
					local shadowRay = accel:Traverse(origin, envDir)
					if not shadowRay then
						local misWeight = Power2Heuristic(envPdf, EvalLambertPDF(result, envDir))
						colour = colour + throughput * EvalLambert(result, envDir) * envCol / envPdf * misWeight
					end
				end

				throughput = throughput * sample.weight

				local rrProb = math.max(throughput[1], throughput[2], throughput[3])
				if sampler:GetFloat() >= rrProb then break end
				throughput = throughput / rrProb

				result = accel:Traverse(origin, sample.scattered)
				if not result then
					local misWeight = Power2Heuristic(sample.pdf, hdri:EvalPDF(sample.scattered))
					colour = colour + throughput * hdri:GetPixel(sample.scattered) * misWeight
					break
				end
			end
		end

		return colour / validSamples
	else
		return hdri:GetPixel(camDir)
	end
end

local y = 0
local setup = true
hook.Add("HUDPaint", "VisTracer", function()
	if y < RESY then
		render.PushRenderTarget(rt)
		if setup then
			render.Clear(0, 0, 0, 0, true, true)
			setup = false
		end

		for x = 0, RESX - 1 do
			local rgb = TracePixel(x, y)
			hdr:SetPixel(x, y, rgb)

			render.SetViewPort(x, y, 1, 1)
			render.Clear(
				math.Clamp(rgb[1] * 255, 0, 255),
				math.Clamp(rgb[2] * 255, 0, 255),
				math.Clamp(rgb[3] * 255, 0, 255),
				255, true, true
			)
		end

		render.PopRenderTarget()
		y = y + 1

		if y >= RESY then
			hdr:Tonemap(true)
			hdr:Save("render.png")
		end
	end

	render.SetMaterial(rtMat)
	render.DrawScreenQuad() -- Draws a quad to the entire screen
end)
