local playGridClass = {}
playGridClass.__index = playGridClass

local unitsInfo = require('unitsInfo')
local fontCache = require('fontCache')
local soundCache = require('soundCache')
local MONOGRAM_FONT_PATH = "assets/fonts/monogram-extended.ttf"

local function getMonogramFont(size)
    return fontCache.get(MONOGRAM_FONT_PATH, size)
end

local function acquireRangedAttackEffect(self)
    local pool = self.rangedAttackEffectPool
    if pool and #pool > 0 then
        local effect = pool[#pool]
        pool[#pool] = nil
        return effect
    end
    return {}
end

function playGridClass:recycleRangedAttackEffect(effect)
    effect.fromRow = nil
    effect.fromCol = nil
    effect.toRow = nil
    effect.toCol = nil
    effect.attackType = nil
    effect.startTime = nil
    effect.duration = nil
    effect.angle = nil
    table.insert(self.rangedAttackEffectPool, effect)
end

local function getDefaultFont(size)
    return fontCache.getDefault(size)
end

local TILE_PATH_EVEN_PRIMARY = "assets/sprites/GrassTile.png"
local TILE_PATH_EVEN_SECONDARY = "assets/sprites/GrassTile1_2.png"
local TILE_PATH_ODD_PRIMARY = "assets/sprites/GrassTile2.png"
local TILE_PATH_ODD_SECONDARY = "assets/sprites/GrassTile2_2.png"

local STATIC_SHADOW_CONFIGS = {
    Bastion = {widthRatio = 0.89, heightRatio = 0.40, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -36, opacity = 0.30},
    Crusher = {widthRatio = 0.85, heightRatio = 0.38, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -36, opacity = 0.30},
    Earthstalker = {widthRatio = 0.75, heightRatio = 0.35, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -26, opacity = 0.30},
    Wingstalker = {widthRatio = 0.60, heightRatio = 0.25, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -22, opacity = 0.20},
    Healer = {widthRatio = 0.65, heightRatio = 0.25, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -24, opacity = 0.20},
    Cloudstriker = {widthRatio = 0.65, heightRatio = 0.30, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -12, opacity = 0.20},
    Artillery = {widthRatio = 0.85, heightRatio = 0.35, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -36, opacity = 0.30},
    Commandant = {widthRatio = 0.85, heightRatio = 0.45, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -36, opacity = 0.30},
    ["Rock 1"] = {widthRatio = 0.65, heightRatio = 0.50, xOffsetRatio = 0.5, xOffsetBias = -2, yOffset = -32, opacity = 0.35},
    ["Rock 2"] = {widthRatio = 0.62, heightRatio = 0.42, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -34, opacity = 0.28},
    ["Rock 3"] = {widthRatio = 0.63, heightRatio = 0.45, xOffsetRatio = 0.5, xOffsetBias = -1, yOffset = -30, opacity = 0.32},
    ["Rock 4"] = {widthRatio = 0.64, heightRatio = 0.48, xOffsetRatio = 0.5, xOffsetBias = -3, yOffset = -34, opacity = 0.38},
    Rock = {widthRatio = 0.62, heightRatio = 0.45, xOffsetRatio = 0.5, xOffsetBias = -2, yOffset = -28, opacity = 0.30}
}

local MOVING_SHADOW_CONFIGS = {
    Bastion = {widthRatio = 0.89, heightRatio = 0.40, yOffset = -36, opacity = 0.30},
    Crusher = {widthRatio = 0.85, heightRatio = 0.38, yOffset = -36, opacity = 0.30},
    Earthstalker = {widthRatio = 0.75, heightRatio = 0.35, yOffset = -26, opacity = 0.30},
    Wingstalker = {widthRatio = 0.60, heightRatio = 0.25, yOffset = -22, opacity = 0.20},
    Healer = {widthRatio = 0.65, heightRatio = 0.25, yOffset = -24, opacity = 0.20},
    Cloudstriker = {widthRatio = 0.65, heightRatio = 0.30, yOffset = -12, opacity = 0.20},
    Artillery = {widthRatio = 0.85, heightRatio = 0.35, yOffset = -36, opacity = 0.30},
    Commandant = {widthRatio = 0.85, heightRatio = 0.45, yOffset = -36, opacity = 0.30},
    Rock = {widthRatio = 0.62, heightRatio = 0.35, yOffset = -28, opacity = 0.30}
}

local DEFAULT_STATIC_PLAYER_SHADOW = {widthRatio = 0.80, heightRatio = 0.35, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -28, opacity = 0.35}
local DEFAULT_STATIC_NEUTRAL_SHADOW = {widthRatio = 0.60, heightRatio = 0.35, xOffsetRatio = 0.5, xOffsetBias = 0, yOffset = -28, opacity = 0.25}
local DEFAULT_MOVING_PLAYER_SHADOW = {widthRatio = 0.80, heightRatio = 0.35, yOffset = -28, opacity = 0.35}
local DEFAULT_MOVING_NEUTRAL_SHADOW = {widthRatio = 0.60, heightRatio = 0.35, yOffset = -28, opacity = 0.25}
local UNIT_COLORS = {
    [0] = {0.7, 0.7, 0.7, 0.9},
    [1] = {0.2, 0.4, 0.9, 0.9},
    [2] = {0.9, 0.3, 0.3, 0.9}
}

local function resolveShadowUnitName(unit)
    if not unit then
        return "Unknown"
    end

    local unitName = unit.name or "Unknown"
    if unitName == "Rock" and unit.path then
        if string.find(unit.path, "NeutralBulding1", 1, true) then
            return "Rock 1"
        elseif string.find(unit.path, "NeutralBulding2", 1, true) then
            return "Rock 2"
        elseif string.find(unit.path, "NeutralBulding3", 1, true) then
            return "Rock 3"
        elseif string.find(unit.path, "NeutralBulding4", 1, true) then
            return "Rock 4"
        end
    end

    return unitName
end

function playGridClass:hasActiveAnimations()
    if not self.movingUnits then
        return false
    end

    return #self.movingUnits > 0
end

-- Helper function to play preview indicator sound
function playGridClass:playPreviewIndicatorSound()
    -- Only play sound if SFX is enabled and we have cells to show
    if SETTINGS and SETTINGS.AUDIO and SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/OpenOrEnable3.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end
end

-- Helper function to play teleport sound effect
function playGridClass:playTeleportSound()
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/SwooshSlide2.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end
end

-- Helper function to play earthquake sound effect
function playGridClass:playEarthquakeSound()
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/Popup4a.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end
end

function playGridClass.new(params)
    local self = setmetatable({}, playGridClass)

    params = params or {}

    -- Store grid dimensions
    self.rows = GAME.CONSTANTS.GRID_SIZE
    self.cols = GAME.CONSTANTS.GRID_SIZE

    -- Store reference to gameRuler if provided
    self.gameRuler = params.gameRuler or nil

    -- Initialize grid cells
    self.cells = {}
    for row = 1, self.rows do
        self.cells[row] = {}
        for col = 1, self.cols do
            self.cells[row][col] = {
                row = row,
                col = col,
                x = GAME.CONSTANTS.GRID_ORIGIN_X + (col - 1) * GAME.CONSTANTS.TILE_SIZE,
                y = GAME.CONSTANTS.GRID_ORIGIN_Y + (row - 1) * GAME.CONSTANTS.TILE_SIZE,
                unit = nil,                  -- Reference to unit in this cell
                terrain = "normal",          -- Terrain type
                setupHighlight = false,      -- For valid Commandant placement during setup
                actionHighlight = nil        -- For highlighting valid actions
            }
        end
    end

    -- Initialize highlighted cells collection
    self.highlightedCells = {}
    self.hasActionHighlights = false

    -- Track Commandants for debugging and repositioning
    self.commandHubs = {}

    -- Flag for tracking if current player is repositioning their Commandant
    self.isRepositioningHub = false
    self.repositioningPlayer = nil
    self.originalHubPosition = nil

    -- Setup phase tracking
    self.setupComplete = {
        [1] = false,  -- Player 1 setup not confirmed
        [2] = false   -- Player 2 setup not confirmed
    }

    -- Animation tracking
    self.movingUnits = {}
    self.animationSpeed = 3  -- Cells per second
    self.minAnimationDuration = 0.18  -- Minimum seconds for very short moves (e.g., melee lunges)

    -- Flash effect tracking
    self.flashingCells = {}

    -- Store unit sprites and tile images
    self.unitImageCache = {}
    self.tileImageCache = {}
    self.tileVariantByCell = {}
    self.coordinateLabelsCanvas = nil
    self.coordinateLabelCacheKey = nil
    
    -- Create procedural background shader (simplified version)
    local success, shader = pcall(love.graphics.newShader, [[
        float hash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
        }
        
        float noise(vec2 p) {
            vec2 i = floor(p);
            vec2 f = fract(p);
            // Use less smoothing for sharper noise
            f = f * f * (2.0 - f);
            
            float a = hash(i);
            float b = hash(i + vec2(1.0, 0.0));
            float c = hash(i + vec2(0.0, 1.0));
            float d = hash(i + vec2(1.0, 1.0));
            
            return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        }
        
        uniform float time;
        uniform vec2 resolution;
        uniform vec2 gridCenter;
        uniform float gridSize;
        uniform float displayScale;
        uniform vec2 displayOffset;
        
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            // Use screen coordinates for consistent texture mapping
            vec2 uv = screen_coords / resolution;
            
            // Enhanced time-based animation with multiple speeds
            float slowTime = time * 0.12; // Increased base animation speed
            float mediumTime = time * 0.25; // Medium speed for secondary effects
            float fastTime = time * 0.4; // Fast speed for subtle details
            
            // Multiple animated drift layers for more dynamic movement
            vec2 drift1 = vec2(sin(slowTime * 0.7) * 0.4, cos(slowTime * 0.5) * 0.3);
            vec2 drift2 = vec2(cos(mediumTime * 0.3) * 0.2, sin(mediumTime * 0.4) * 0.25);
            vec2 p = uv * 18.0 + drift1 + drift2;
            
            // Multi-octave noise with animated offsets for each layer
            float n1 = noise(p + vec2(slowTime * 0.2, slowTime * 0.15));
            float n2 = noise(p * 2.5 + vec2(1.7 + mediumTime * 0.1, 2.3 + mediumTime * 0.08));
            float n3 = noise(p * 5.2 + vec2(5.1 + fastTime * 0.05, 1.9 + fastTime * 0.06));
            float n4 = noise(p * 10.8 + vec2(3.2 + fastTime * 0.03, 4.8 + fastTime * 0.04));
            
            // Combine noise layers with animated weights
            float weight1 = 0.35 + sin(slowTime * 0.6) * 0.05;
            float weight2 = 0.25 + cos(mediumTime * 0.4) * 0.03;
            float combined = n1 * weight1 + n2 * weight2 + n3 * 0.25 + n4 * 0.15;
            
            // Enhanced directional grain with pulsing animation
            float grainPulse = 1.0 + sin(mediumTime * 1.2) * 0.3;
            float grain = sin(p.x * 1.5 + combined * 5.0 + slowTime * 0.5) * 0.15 * grainPulse;
            combined += grain;
            
            // Multiple animated swirl layers for more dynamic organic movement
            float swirl1 = sin(p.x * 0.4 + p.y * 0.6 + combined * 3.0 + slowTime * 1.2) * 0.12;
            float swirl2 = sin(p.x * 0.7 - p.y * 0.3 + combined * 2.5 + mediumTime * 0.8) * 0.1;
            float swirl3 = cos(p.x * 0.3 + p.y * 0.8 + combined * 4.0 + fastTime * 0.6) * 0.08;
            combined += swirl1 + swirl2 + swirl3;
            
            // Enhance contrast and clamp for sharper details
            combined = clamp(combined, 0.0, 1.0);
            combined = pow(combined, 0.6); // More contrast for sharper appearance
            
            // Color palette matching papyrus/parchment - warm orange tones
            vec3 darkBrown = vec3(0.58, 0.48, 0.32);    // Warmer darker areas with orange tint
            vec3 mediumBrown = vec3(0.72, 0.62, 0.45);  // Medium orange-brown tones
            vec3 lightBrown = vec3(0.82, 0.74, 0.58);   // Light warm brown with orange
            vec3 tan = vec3(0.88, 0.82, 0.68);          // Warm tan with orange undertones
            vec3 lightTan = vec3(0.94, 0.90, 0.80);     // Very light warm papyrus with orange
            
            // Multi-zone color mixing for natural variation
            vec3 finalColor;
            if (combined < 0.2) {
                finalColor = mix(darkBrown, mediumBrown, combined / 0.2);
            } else if (combined < 0.4) {
                finalColor = mix(mediumBrown, lightBrown, (combined - 0.2) / 0.2);
            } else if (combined < 0.7) {
                finalColor = mix(lightBrown, tan, (combined - 0.4) / 0.3);
            } else {
                finalColor = mix(tan, lightTan, (combined - 0.7) / 0.3);
            }
            
            // Add subtle surface variation
            float surface = noise(p * 24.0) * 0.04;
            finalColor += surface;
            
            // Enhanced animated warmth variation with multiple breathing patterns
            float warmth = noise(p * 6.0 + vec2(slowTime * 0.1, mediumTime * 0.08)) * 0.025; // Animated warmth variation
            float breathing1 = sin(slowTime * 1.4) * 0.03; // Primary breathing effect
            float breathing2 = cos(mediumTime * 0.8) * 0.02; // Secondary breathing pattern
            float pulse = sin(fastTime * 0.5) * 0.015; // Fast subtle pulse
            
            // Animated color shifts with multiple frequencies
            finalColor.r += warmth + (breathing1 + pulse) * 1.3; // Enhanced red/orange component
            finalColor.g += warmth * 0.9 + (breathing1 + breathing2) * 1.0; // Warm orange-yellow with dual breathing
            finalColor.b += (breathing2 + pulse) * 0.2; // Subtle blue variation for depth
            
            // Add stronger vignette effect centered on the play grid
            // Convert screen coordinates to actual window coordinates
            vec2 windowCoords = screen_coords;
            
            // Apply the same transformation as the game's coordinate system
            vec2 transformedCoords = (windowCoords - displayOffset) / displayScale;
            
            // Calculate distance from grid center in game coordinate space
            float distFromGridCenter = distance(transformedCoords, gridCenter);
            
            // Scale vignette based on grid size in game coordinate space
            float vignetteRadius = gridSize * 0.85; // Vignette covers 85% of grid area (balanced)
            float vignette = 1.0 - smoothstep(vignetteRadius * 0.4, vignetteRadius, distFromGridCenter);
            vignette = pow(vignette, 0.5); // Balanced vignette curve
            
            // Apply vignette by darkening edges
            finalColor *= mix(0.4, 1.0, vignette); // Darken edges to 40% brightness
            
            return vec4(finalColor, 1.0);
        }
    ]])
    
    if success then
        self.backgroundShader = shader
    else
        self.backgroundShader = nil
    end

    self.selectedGridUnit = nil

    -- Mouse hover tracking
    self.mouseHoverCell = nil
    self.hoverIndicatorColor = {203/255, 183/255, 158/255, 0.9} -- Neutral tan color
    self.actionIndicatorColor = nil
    self.triangleRotation = 0

    -- Keyboard navigation tracking
    self.keyboardSelectedCell = {row = 1, col = 1}

    -- UI navigation flag - initialize to false
    self.uiNavigationActive = false

    self.damagedUnits = {}
    self.damagedUnitLookup = {}
    self.damagedUnitLookupDirty = true

    self.floatingTexts = {}
    self.damageTextFont = getDefaultFont(SETTINGS.FONT.TITLE_SIZE)

    -- Add tracking for destruction particles
    self.destructionEffects = {}
    self.destructionEffectPool = {}
    self.destructionParticlePool = {}

    self.rangedAttackEffects = {}
    self.rangedAttackEffectPool = {}

    self.commandHubZoomEffects = {}

    -- Create a reusable particle image
    local particleCanvas = love.graphics.newCanvas(6, 6)
    love.graphics.setCanvas(particleCanvas)
    love.graphics.clear()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, 6, 6)
    love.graphics.setCanvas()
    self.particleImage = love.graphics.newImage(particleCanvas:newImageData())

    -- Add screen shake system
    self.screenShake = {
        active = false,
        intensity = 0,
        duration = 0,
        startTime = 0,
        offsetX = 0,
        offsetY = 0
    }

    self.whiteShader = love.graphics.newShader([[
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            vec4 texColor = Texel(texture, texture_coords);
            // Set RGB to white while preserving the texture's original alpha
            return vec4(1.0, 1.0, 1.0, texColor.a * color.a);
        }
    ]])

    self.buildingMaterializeShader = love.graphics.newShader([[
        extern float progress;
        
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            vec4 texcolor = Texel(texture, texture_coords);
            
            // Simple white flash that fades to original color
            vec3 whiteColor = vec3(1.0, 1.0, 1.0);
            vec3 finalColor = mix(whiteColor, texcolor.rgb, progress);
            
            // Ensure we keep the original alpha
            return vec4(finalColor, texcolor.a * color.a);
        }
    ]])

    -- Wind shader for grass tiles - creates subtle linear movement
    self.windShader = love.graphics.newShader([[
        extern float time;
        extern vec2 windDirection;
        extern float windStrength;
        
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            // Create linear wind waves that move in wind direction only
            float windX = windDirection.x * screen_coords.x * 0.005;
            float windY = windDirection.y * screen_coords.y * 0.005;
            
            // Single wave moving in wind direction - no circular patterns
            float wave = sin(time * 1.0 + windX + windY) * windStrength;
            
            // Apply very subtle texture coordinate offset only in wind direction
            vec2 windOffset = windDirection * wave * 0.001; // Even more subtle
            vec2 newTexCoords = texture_coords + windOffset;
            
            // Sample texture with wind-displaced coordinates
            vec4 texcolor = Texel(texture, newTexCoords);
            
            // Minimal color variation
            float lightVariation = 1.0 + wave * 0.02;
            texcolor.rgb *= lightVariation;
            
            return texcolor * color;
        }
    ]])

    self.hologramShader = love.graphics.newShader([[
        extern float time;
        
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            vec4 texcolor = Texel(texture, texture_coords);
            
            // Base hologram color (blue tint)
            vec3 holoColor = vec3(0.5, 0.8, 1.0); 
            
            // Scanline effect
            float scanlines = sin(screen_coords.y * 0.5 + time * 2.0) * 0.15 + 0.85;
            
            // Edge highlight effect
            float edgex = abs(texture_coords.x - 0.5) * 2.0;
            float edgey = abs(texture_coords.y - 0.5) * 2.0;
            float edge = max(edgex, edgey);
            float edgeGlow = pow(edge, 3.0) * 0.5;
            
            // Flickering effect
            float flicker = 0.95 + sin(time * 3.0) * 0.05;
            
            // Final color calculation
            vec3 finalColor = mix(holoColor, texcolor.rgb, 0.3) * scanlines * flicker + vec3(edgeGlow);
            
            // Alpha calculation (slightly transparent)
            float alpha = texcolor.a * 0.8;
            
            return vec4(finalColor, alpha * color.a);
        }
    ]])

    -- Add Tesla strike effects tracking
    self.teslaStrikeEffects = {}
    
    -- Create irregular projectile shader for Artillery
    self.irregularProjectileShader = love.graphics.newShader([[
        extern float time;
        extern vec2 center;
        extern float radius;
        
        // Noise function for irregular shape
        float noise(vec2 p) {
            return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
        }
        
        // Multi-octave noise for more complex patterns
        float fbm(vec2 p) {
            float value = 0.0;
            float amplitude = 0.5;
            for (int i = 0; i < 4; i++) {
                value += amplitude * noise(p);
                p *= 2.0;
                amplitude *= 0.5;
            }
            return value;
        }
        
        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
            vec2 pos = screen_coords - center;
            float dist = length(pos);
            
            // Create irregular boundary using noise
            float angle = atan(pos.y, pos.x);
            float noiseValue = fbm(vec2(angle * 3.0, time * 2.0)) * 0.3 + 0.7;
            float irregularRadius = radius * noiseValue;
            
            // Create dark interior with irregular edges
            if (dist < irregularRadius) {
                // Dark interior with slight variation
                float innerNoise = fbm(pos * 0.1 + time) * 0.1;
                vec3 darkColor = vec3(0.1 + innerNoise, 0.1 + innerNoise, 0.1 + innerNoise);
                return vec4(darkColor, color.a * 0.8);
            }
            
            // Outside the irregular shape - transparent
            return vec4(0.0, 0.0, 0.0, 0.0);
        }
    ]])
    
    -- Matrix transformation-based idle animation will be handled in Lua code
    self.idleUnitShader = nil
    
    -- Create Tesla lightning shader
    -- Update the Tesla lightning shader in playGridClass.new():
self.teslaShader = love.graphics.newShader([[
    extern float time;
    extern vec2 startPos;
    extern vec2 endPos;
    extern float intensity;
    extern float thickness;
    extern vec2 resolution;
    
    // Noise function for electric arc variation
    float noise(vec2 p) {
        return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
    }
    
    vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
        // NORMALIZE screen coordinates
        vec2 normalizedCoords = screen_coords / resolution;
        vec2 normalizedStart = startPos / resolution;
        vec2 normalizedEnd = endPos / resolution;
        
        // Calculate distance from point to line (using normalized coordinates)
        vec2 lineDir = normalize(normalizedEnd - normalizedStart);
        vec2 perpDir = vec2(-lineDir.y, lineDir.x);
        
        vec2 toPoint = normalizedCoords - normalizedStart;
        float alongLine = dot(toPoint, lineDir);
        float perpDist = abs(dot(toPoint, perpDir));
        
        // Length of the line
        float lineLength = distance(normalizedStart, normalizedEnd);
        
        // Check if point is along the line segment
        if (alongLine < 0.0 || alongLine > lineLength) {
            return vec4(0.0);
        }
        
        float progress = alongLine / lineLength;
        
        // MOLTO PIÙ COMPATTO - noise ridotto per raggio più focale
        float noise1 = noise(vec2(progress * 12.0, time * 8.0)) - 0.5;
        float noise2 = noise(vec2(progress * 24.0, time * 16.0)) - 0.5;
        float noise3 = noise(vec2(progress * 48.0, time * 32.0)) - 0.5;
        
        // ZIGZAG MOLTO PIÙ PICCOLO per un raggio più dritto e compatto
        float zigzag = (noise1 * 2.0 + noise2 * 1.0 + noise3 * 0.5) * intensity * 0.01; // MOLTO ridotto
        
        float arcThickness = (thickness / resolution.x) * (1.0 + sin(progress * 3.14159) * 0.2); // Meno variazione
        
        float distFromArc = abs(perpDist - zigzag);
        
        float coreAlpha = 1.0 - smoothstep(0.0, arcThickness * 0.18, distFromArc); // Core più piccolo
        vec3 coreColor = vec3(0.8, 0.95, 1.0);  // Bianco-blu più intenso
        
        float glowAlpha = (1.0 - smoothstep(0.0, arcThickness * 0.5, distFromArc)) * 0.8; // Glow più piccolo
        vec3 glowColor = vec3(0.3, 0.6, 1.0);  // Blu più intenso
        
        float sparkNoise = noise(vec2(progress * 25.0, time * 20.0));
        if (sparkNoise > 0.92 && distFromArc < arcThickness * 0.1) { // Soglia più alta, area più piccola
            coreAlpha += 0.8; // Scintille più intense
            coreColor = vec3(1.0, 1.0, 1.0);  // Bianco puro per le scintille
        }
        // Final color blending
        vec3 finalColor = mix(glowColor, coreColor, smoothstep(0.0, 1.0, coreAlpha));
        float finalAlpha = max(coreAlpha * 1.2, glowAlpha) * intensity; // Core più opaco
        
        return vec4(finalColor, finalAlpha);
    }
]])

    -- Add impact effects tracking
    self.impactEffects = {}

    -- Default wind shader parameters and cached uniform state
    self.windDirection = {0.7, 0.3}
    self.windStrength = 0.8
    self._windUniformsCache = {
        time = nil,
        direction = nil,
        strength = nil
    }

    -- Create a dust particle image if not already created
    if not self.particleImage then
        local particleCanvas = love.graphics.newCanvas(6, 6)
        love.graphics.setCanvas(particleCanvas)
        love.graphics.clear()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, 6, 6)
        love.graphics.setCanvas()
        self.particleImage = love.graphics.newImage(particleCanvas:newImageData())
    end

    self:rebuildTileVariantCache()

    return self
end


function playGridClass:init()
    self.highlightedCells = {}
    self.hasActionHighlights = false
    self.commandHubs = {}
    self.isRepositioningHub = false
    self.repositioningPlayer = nil
    self.originalHubPosition = nil
    self.setupComplete = {
        [1] = false,
        [2] = false
    }
    self.movingUnits = {}
    self.animationSpeed = 3
    self.minAnimationDuration = 0.18
    self.flashingCells = {}
    self.unitImageCache = {}
    self.tileImageCache = {}
    self:rebuildTileVariantCache()
    self:invalidateCoordinateLabelCache()
    self.selectedGridUnit = nil
    self.mouseHoverCell = nil
    self.hoverIndicatorColor = {203/255, 183/255, 158/255, 0.9}
    self.actionIndicatorColor = nil
    self.triangleRotation = 0
    self.keyboardSelectedCell = {row = 1, col = 1}
    self.uiNavigationActive = false
    self.damagedUnits = {}
    self.damagedUnitLookup = {}
    self.damagedUnitLookupDirty = true
    self.floatingTexts = {}
    self.damageTextFont = getDefaultFont(SETTINGS.FONT.TITLE_SIZE)
    self.destructionEffects = {}
    self.commandHubZoomEffects = {}
    self._setupHighlightedCells = {}
    self._setupHighlightedMap = {}
    self._cachedPreviewDraws = {}
    self.screenShake = {
        active = false,
        intensity = 0,
        duration = 0,
        startTime = 0,
        offsetX = 0,
        offsetY = 0
    }
    self.teslaStrikeEffects = {}
    self.impactEffects = {}
end

function playGridClass:rebuildTileVariantCache()
    self.tileVariantByCell = self.tileVariantByCell or {}
    for row = 1, self.rows do
        local rowBucket = self.tileVariantByCell[row] or {}
        self.tileVariantByCell[row] = rowBucket
        for col = 1, self.cols do
            local isEvenCell = (row + col) % 2 == 0
            local hash = (row * 73 + col * 37) % 100
            if isEvenCell then
                if hash < 50 then
                    rowBucket[col] = TILE_PATH_EVEN_PRIMARY
                else
                    rowBucket[col] = TILE_PATH_EVEN_SECONDARY
                end
            else
                if hash < 50 then
                    rowBucket[col] = TILE_PATH_ODD_PRIMARY
                else
                    rowBucket[col] = TILE_PATH_ODD_SECONDARY
                end
            end
        end
    end
end

function playGridClass:invalidateCoordinateLabelCache()
    self.coordinateLabelCacheKey = nil
    if self.coordinateLabelsCanvas then
        self.coordinateLabelsCanvas:release()
        self.coordinateLabelsCanvas = nil
    end
end

function playGridClass:ensureCoordinateLabelCanvas()
    if not (SETTINGS and SETTINGS.PERF and SETTINGS.PERF.DRAW_CACHE_ENABLED) then
        return nil
    end

    local cacheKey = table.concat({
        tostring(SETTINGS.FONT.BIG_SIZE),
        tostring(self.rows),
        tostring(self.cols),
        tostring(GAME.CONSTANTS.TILE_SIZE),
        tostring(GAME.CONSTANTS.GRID_ORIGIN_X),
        tostring(GAME.CONSTANTS.GRID_ORIGIN_Y),
        tostring(SETTINGS.DISPLAY.WIDTH),
        tostring(SETTINGS.DISPLAY.HEIGHT)
    }, "|")

    if self.coordinateLabelCacheKey == cacheKey and self.coordinateLabelsCanvas then
        return self.coordinateLabelsCanvas
    end

    self:invalidateCoordinateLabelCache()

    local success, canvas = pcall(
        love.graphics.newCanvas,
        SETTINGS.DISPLAY.WIDTH,
        SETTINGS.DISPLAY.HEIGHT
    )
    if not success then
        return nil
    end

    self.coordinateLabelsCanvas = canvas
    self.coordinateLabelCacheKey = cacheKey

    local previousCanvas = love.graphics.getCanvas()
    local defaultFont = love.graphics.getFont()
    local coordinateFont = getMonogramFont(SETTINGS.FONT.BIG_SIZE)

    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setFont(coordinateFont)
    love.graphics.setColor(46/255, 38/255, 32/255)

    for col = 1, self.cols do
        local letter = string.char(64 + col)
        local xPos = GAME.CONSTANTS.GRID_ORIGIN_X + (col - 1) * GAME.CONSTANTS.TILE_SIZE + GAME.CONSTANTS.TILE_SIZE/2 - 6
        local yPos = GAME.CONSTANTS.GRID_ORIGIN_Y - 32
        love.graphics.print(letter, xPos, yPos)
    end

    for row = 1, self.rows do
        local num = tostring(row)
        local xPos = GAME.CONSTANTS.GRID_ORIGIN_X - 20
        local yPos = GAME.CONSTANTS.GRID_ORIGIN_Y + (row - 1) * GAME.CONSTANTS.TILE_SIZE + GAME.CONSTANTS.TILE_SIZE/2 - 12
        love.graphics.print(num, xPos, yPos)
    end

    love.graphics.setCanvas(previousCanvas)
    love.graphics.setFont(defaultFont)

    return canvas
end

function playGridClass:rebuildDamagedUnitLookup()
    if not self.damagedUnitLookupDirty then
        return
    end

    local lookup = {}
    for _, damaged in ipairs(self.damagedUnits or {}) do
        local rowBucket = lookup[damaged.row]
        if not rowBucket then
            rowBucket = {}
            lookup[damaged.row] = rowBucket
        end
        rowBucket[damaged.col] = true
    end

    self.damagedUnitLookup = lookup
    self.damagedUnitLookupDirty = false
end

function playGridClass:createTeslaStrike(hubRow, hubCol, targetRow, targetCol)
    local hubCell = self:getCell(hubRow, hubCol)
    local targetCell = self:getCell(targetRow, targetCol)

    if not hubCell or not targetCell then return end

    -- Calculate positions
    local hubCenterX = hubCell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local hubCenterY = hubCell.y + GAME.CONSTANTS.TILE_SIZE / 2
    local targetCenterX = targetCell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local targetCenterY = targetCell.y + GAME.CONSTANTS.TILE_SIZE / 2

    -- Create Tesla strike effect
    local effect = {
        startTime = love.timer.getTime(),
        duration = 0.4,  -- 400ms strike
        hubRow = hubRow,
        hubCol = hubCol,
        targetRow = targetRow,
        targetCol = targetCol,
        startPos = {hubCenterX, hubCenterY},
        endPos = {targetCenterX, targetCenterY},
        intensity = 1.0,
        thickness = 18,  -- INCREASED from 12 to 18 (bigger base thickness)
        phase = "buildup"  -- buildup -> strike -> fade
    }
    
    -- Add to effects list
    if not self.teslaStrikeEffects then
        self.teslaStrikeEffects = {}
    end
    table.insert(self.teslaStrikeEffects, effect)
    
    -- Create ELECTRIC SPARK impact effect instead of sphere
    self:createElectricImpactEffect(targetCenterX, targetCenterY)
    
    -- Flash the target cell with blue
    self:flashCell(targetRow, targetCol, {0.4, 0.8, 1.0})

    return effect
end

function playGridClass:createElectricImpactEffect(x, y)
    -- Create a small particle image for sparks if we haven't already
    if not self.sparkParticleImage then
        local particleCanvas = love.graphics.newCanvas(4, 4)
        love.graphics.setCanvas(particleCanvas)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, 4, 4)  -- Small square spark
        love.graphics.setCanvas()
        self.sparkParticleImage = love.graphics.newImage(particleCanvas:newImageData())
    end

    -- Create particle system for electric sparks
    local particleSystem = love.graphics.newParticleSystem(self.sparkParticleImage, 30)

    -- Configure for electric spark effect
    particleSystem:setParticleLifetime(0.1, 0.3)      -- Very short lifetime
    particleSystem:setEmissionRate(0)                 -- No continuous emission
    particleSystem:setEmissionArea("ellipse", 20, 20, 0, false) -- Smaller area

    -- Fast outward burst
    particleSystem:setRadialAcceleration(80, 150)     -- Strong outward push
    particleSystem:setSpeed(10, 40)                   -- Fast initial speed
    particleSystem:setSpread(math.pi * 2)             -- 360-degree spread
    particleSystem:setLinearDamping(3.0)              -- Quick deceleration
    particleSystem:setSizes(0.3, 0.6, 0.1)           -- Small sparks
    particleSystem:setSizeVariation(0.5)              -- Size variation

    -- Electric blue colors
    particleSystem:setColors(
        0.9, 0.95, 1.0, 0.9,   -- Bright blue-white
        0.4, 0.8, 1.0, 0.6,    -- Electric blue
        0.2, 0.5, 1.0, 0.0     -- Deep blue fade
    )

    -- Add rotation for spark effect
    particleSystem:setRotation(0, math.pi*2)
    particleSystem:setSpin(5, 15)

    -- Emit a burst of sparks
    particleSystem:emit(30)

    -- Create the impact effect record
    local effect = {
        x = x,
        y = y,
        system = particleSystem,
        startTime = love.timer.getTime(),
        duration = 0.4,  -- Short duration for sparks
        type = "electric"
    }

    -- Add to active effects
    table.insert(self.impactEffects, effect)

    return effect
end

function playGridClass:updateTeslaStrikeEffects(dt, now)
    if not self.teslaStrikeEffects then return end

    local currentTime = now or love.timer.getTime()

    for i = #self.teslaStrikeEffects, 1, -1 do
        local effect = self.teslaStrikeEffects[i]
        local elapsed = currentTime - effect.startTime
        local progress = elapsed / effect.duration
        
        if progress >= 1.0 then
            -- Remove completed effect
            table.remove(self.teslaStrikeEffects, i)
        else
            -- Update effect phases with BIGGER thickness values
            if progress < 0.2 then
                -- BUILDUP phase (0-20%): intensity grows
                effect.phase = "buildup"
                effect.intensity = progress / 0.2
                effect.thickness = 8 + (progress / 0.2) * 8  -- INCREASED from 6+6 to 8+8
                
            elseif progress < 0.7 then
                -- STRIKE phase (20-70%): full intensity with crackling
                effect.phase = "strike"
                effect.intensity = 1.0 + math.sin(currentTime * 30) * 0.2
                effect.thickness = 16 + math.sin(currentTime * 25) * 4  -- INCREASED from 12+3 to 16+4
                
            else
                -- FADE phase (70-100%): intensity decreases
                effect.phase = "fade"
                local fadeProgress = (progress - 0.7) / 0.3
                effect.intensity = (1.0 - fadeProgress) * (0.8 + math.sin(currentTime * 20) * 0.15)
                effect.thickness = 12 * (1.0 - fadeProgress)  -- INCREASED from 8 to 12
            end
        end
    end
end

function playGridClass:drawTeslaStrikeEffects()
    if not self.teslaStrikeEffects then return end
    
    for _, effect in ipairs(self.teslaStrikeEffects) do
        -- CONVERT GAME COORDINATES TO ACTUAL SCREEN COORDINATES
        local screenStartX = (effect.startPos[1] * SETTINGS.DISPLAY.SCALE) + SETTINGS.DISPLAY.OFFSETX
        local screenStartY = (effect.startPos[2] * SETTINGS.DISPLAY.SCALE) + SETTINGS.DISPLAY.OFFSETY
        local screenEndX = (effect.endPos[1] * SETTINGS.DISPLAY.SCALE) + SETTINGS.DISPLAY.OFFSETX
        local screenEndY = (effect.endPos[2] * SETTINGS.DISPLAY.SCALE) + SETTINGS.DISPLAY.OFFSETY
        
        -- Set up shader uniforms with SCREEN coordinates
        self.teslaShader:send("time", love.timer.getTime())
        self.teslaShader:send("startPos", {screenStartX, screenStartY})
        self.teslaShader:send("endPos", {screenEndX, screenEndY})
        self.teslaShader:send("intensity", effect.intensity)
        self.teslaShader:send("thickness", effect.thickness * SETTINGS.DISPLAY.SCALE * 1.0)
        self.teslaShader:send("resolution", {SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT})
        
        -- Apply shader and draw effect area
        love.graphics.setShader(self.teslaShader)
        love.graphics.setBlendMode("add", "alphamultiply")
        love.graphics.setColor(1, 1, 1, 1)
        
        -- Calculate bounding box with more padding for bigger lightning
        local minX = math.min(effect.startPos[1], effect.endPos[1]) - effect.thickness * 1.5  -- INCREASED padding
        local maxX = math.max(effect.startPos[1], effect.endPos[1]) + effect.thickness * 1.5  -- INCREASED padding
        local minY = math.min(effect.startPos[2], effect.endPos[2]) - effect.thickness * 1.5  -- INCREASED padding
        local maxY = math.max(effect.startPos[2], effect.endPos[2]) + effect.thickness * 1.5  -- INCREASED padding
        
        -- Draw rectangle covering the lightning path (in game coordinates)
        love.graphics.rectangle("fill", minX, minY, maxX - minX, maxY - minY)
        
        -- Reset shader and blend mode
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha")
        
        -- MUCH BIGGER and MORE VISIBLE source and target glow effects
        if effect.phase == "strike" or effect.phase == "fade" then
            -- === SOURCE HUB GLOW - MULTI-LAYER EFFECT ===
            love.graphics.setBlendMode("add", "alphamultiply")
            
            -- Outer glow ring (largest)
            love.graphics.setColor(0.1, 0.4, 0.8, effect.intensity * 0.15)  -- Deep blue outer
            love.graphics.circle("fill", effect.startPos[1], effect.startPos[2], 35 * effect.intensity)
            
            -- Middle glow ring
            love.graphics.setColor(0.2, 0.6, 1.0, effect.intensity * 0.25)  -- Medium blue
            love.graphics.circle("fill", effect.startPos[1], effect.startPos[2], 25 * effect.intensity)
            
            -- Inner bright core
            love.graphics.setColor(0.4, 0.8, 1.0, effect.intensity * 0.4)  -- Bright blue core
            love.graphics.circle("fill", effect.startPos[1], effect.startPos[2], 15 * effect.intensity)
            
            -- Very bright center point
            love.graphics.setColor(0.7, 0.9, 1.0, effect.intensity * 0.6)  -- Nearly white center
            love.graphics.circle("fill", effect.startPos[1], effect.startPos[2], 8 * effect.intensity)
            
            -- === TARGET IMPACT GLOW - SMALLER BUT STILL VISIBLE ===
            -- Outer impact ring
            love.graphics.setColor(0.3, 0.7, 1.0, effect.intensity * 0.2)  -- Blue impact
            love.graphics.circle("fill", effect.endPos[1], effect.endPos[2], 18 * effect.intensity)
            
            -- Inner impact core
            love.graphics.setColor(0.5, 0.9, 1.0, effect.intensity * 0.3)  -- Bright impact
            love.graphics.circle("fill", effect.endPos[1], effect.endPos[2], 10 * effect.intensity)
            
            love.graphics.setBlendMode("alpha")
        end
    end
    
    -- Reset graphics state
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:startScreenShake(intensity, duration)
    self.screenShake = {
        active = true,
        intensity = intensity or 6,  -- Maximum shake intensity in pixels
        duration = duration or 0.4,  -- Duration in seconds
        startTime = love.timer.getTime(),
        offsetX = 0,
        offsetY = 0
    }
end

-- Update screen shake in update function
function playGridClass:updateScreenShake(dt, now)
    if not self.screenShake.active then return end

    local currentTime = now or love.timer.getTime()
    local elapsed = currentTime - self.screenShake.startTime

    -- Check if shake effect is over
    if elapsed >= self.screenShake.duration then
        self.screenShake.active = false
        self.screenShake.offsetX = 0
        self.screenShake.offsetY = 0
        return
    end

    -- Calculate shake intensity based on remaining time (gradually diminishes)
    local progress = elapsed / self.screenShake.duration
    local currentIntensity = self.screenShake.intensity * (1 - progress)

    -- Generate subtle earthquake-like random offsets for both axes
    local time = currentTime
    local fastShake = math.sin(time * 50) * 0.3  -- High frequency component
    local slowShake = math.sin(time * 8) * 0.7   -- Low frequency component
    
    -- Combine random and sine-based movement for natural earthquake feel
    self.screenShake.offsetX = ((math.random() - 0.5) + fastShake + slowShake) * currentIntensity * 1.5
    self.screenShake.offsetY = ((math.random() - 0.5) + math.sin(time * 45) * 0.4 + math.sin(time * 12) * 0.6) * currentIntensity * 1.5
end

local function acquireDestructionEffect(self)
    local pool = self.destructionEffectPool
    if pool and #pool > 0 then
        local effect = pool[#pool]
        pool[#pool] = nil
        return effect
    end
    return {}
end

local function acquireDestructionParticle(self)
    local pool = self.destructionParticlePool
    if pool and #pool > 0 then
        local particle = pool[#pool]
        pool[#pool] = nil
        return particle
    end
    return {}
end

function playGridClass:recycleDestructionEffect(effect)
    if effect.type == "physicsDebris" and effect.particles then
        for i = #effect.particles, 1, -1 do
            local particle = effect.particles[i]
            effect.particles[i] = nil
            particle.x = 0
            particle.y = 0
            particle.vx = 0
            particle.vy = 0
            particle.rotation = 0
            particle.spin = 0
            particle.size = 0
            particle.life = 0
            table.insert(self.destructionParticlePool, particle)
        end
    end

    if effect.system and effect.system.reset then
        effect.system:reset()
    end

    effect.type = nil
    effect.system = nil
    effect.particles = effect.particles or {}
    effect.duration = nil
    effect.startTime = nil
    effect.x = nil
    effect.y = nil
    effect.cellBounds = nil
    effect.groundY = nil
    effect.hasBounceEffect = nil
    effect.factionDebrisCreated = nil
    effect.playerColor = nil

    table.insert(self.destructionEffectPool, effect)
end

function playGridClass:createDestructionEffect(row, col, playerColor)
    local cell = self:getCell(row, col)
    if not cell then return end

    -- Simple screen shake
    self:startScreenShake(8, 0.8)

    -- Create main fountain explosion (neutral colors) - MORE CONTAINED
    local particleSystem = love.graphics.newParticleSystem(self.particleImage, 80)  -- Fewer particles

    -- MAIN FOUNTAIN CONFIGURATION - MORE CONTAINED
    particleSystem:setParticleLifetime(1.0, 1.5)  -- Shorter lifetime
    particleSystem:setEmissionRate(0)
    particleSystem:setEmissionArea("ellipse", 12, 12, 0, false)  -- Smaller emission area

    -- FOUNTAIN PHYSICS - FASTER FALLING
    particleSystem:setLinearAcceleration(0, 120, 0, 180)  -- MUCH HIGHER gravity for faster falling
    particleSystem:setSpeed(40, 80)  -- Lower initial velocity
    particleSystem:setDirection(-math.pi/2)  -- Point upward
    particleSystem:setSpread(math.pi * 0.6)  -- Narrower spread
    particleSystem:setLinearDamping(0.1, 0.3)  -- MUCH LOWER damping for faster falling

    -- SIZE AND SCALING
    particleSystem:setSizes(1.2, 0.8, 0.4, 0.1, 0.0)
    particleSystem:setSizeVariation(0.4)

    -- UNIVERSAL WHITE-TO-WHITISH COLOR PROGRESSION
    particleSystem:setColors(
        1.0, 1.0, 1.0, 1.0,      -- Pure white start
        0.95, 0.95, 0.95, 0.9,   -- Very light gray
        0.9, 0.9, 0.9, 0.8,      -- Light gray
        0.85, 0.85, 0.85, 0.6,   -- Medium light gray
        0.8, 0.8, 0.8, 0.4,      -- Medium gray
        0.75, 0.75, 0.75, 0.2,   -- Darker gray
        0.7, 0.7, 0.7, 0.0       -- Fade to dark gray
    )

    -- ROTATION
    particleSystem:setRotation(0, math.pi * 2)
    particleSystem:setSpin(-1.5, 1.5)  -- Slower spin
    particleSystem:setSpinVariation(1)

    -- Emit main explosion
    particleSystem:emit(80)  -- Fewer particles

    -- Store main effect
    local effect = acquireDestructionEffect(self)
    effect.type = "particles"
    effect.x = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
    effect.y = cell.y + GAME.CONSTANTS.TILE_SIZE / 2
    effect.system = particleSystem
    effect.startTime = love.timer.getTime()
    effect.duration = 1.5
    effect.groundY = cell.y + GAME.CONSTANTS.TILE_SIZE - 10
    effect.hasBounceEffect = true
    effect.playerColor = playerColor
    effect.cellBounds = effect.cellBounds or {}
    effect.cellBounds.left = cell.x
    effect.cellBounds.right = cell.x + GAME.CONSTANTS.TILE_SIZE
    effect.cellBounds.top = cell.y
    effect.cellBounds.bottom = cell.y + GAME.CONSTANTS.TILE_SIZE

    table.insert(self.destructionEffects, effect)
    self:flashCell(row, col, {1.0, 0.8, 0.4})

    return effect
end

function playGridClass:easeInOutQuart(t)
    -- Quartic ease-in-out: rapid start, slow middle, rapid end
    if t < 0.5 then
        return 8 * t * t * t * t
    else
        local f = t - 1
        return 1 - 8 * f * f * f * f
    end
end

function playGridClass:easeInOutCubic(t)
    -- Cubic ease-in-out: rapid start, smooth middle, rapid end
    if t < 0.5 then
        return 4 * t * t * t
    else
        local f = t - 1
        return 1 + 4 * f * f * f
    end
end

function playGridClass:updateDestructionEffects(dt, now)
    local currentTime = now or love.timer.getTime()

    for i = #self.destructionEffects, 1, -1 do
        local effect = self.destructionEffects[i]

        if effect.type == "explosion" then
            -- Handle old shader-based explosion effects (if any still exist)
            effect.timeElapsed = currentTime - effect.startTime

            -- Update explosion phases
            if effect.timeElapsed < 0.3 then
                effect.currentPhase = "ignition"
                effect.intensity = effect.timeElapsed / 0.3
            elseif effect.timeElapsed < 0.8 then
                effect.currentPhase = "expansion"
                effect.intensity = 1.0
            elseif effect.timeElapsed < 1.2 then
                effect.currentPhase = "shockwave"
                local fadeProgress = (effect.timeElapsed - 0.8) / 0.4
                effect.intensity = 1.0 - fadeProgress
            else
                effect.currentPhase = "fade"
                local fadeProgress = (effect.timeElapsed - 1.2) / 0.3
                effect.intensity = math.max(0, 1.0 - fadeProgress)
            end

            -- Remove if duration expired
            if effect.timeElapsed >= 1.5 then
                self:recycleDestructionEffect(effect)
                table.remove(self.destructionEffects, i)
            end

        elseif effect.type == "particles" then
            -- Handle particle-based effects (main fountain explosion)
            effect.system:update(dt)

            -- Handle preview clearing for animations with delay
            if effect.previewClearTime and currentTime >= effect.previewClearTime then
                self:clearForcedHighlightedCells()
                effect.previewClearTime = nil  -- Clear the timer so we don't repeat
            end

            -- CREATE FACTION-COLORED BOUNCING DEBRIS WITH PHYSICS SIMULATION
            if effect.hasBounceEffect and not effect.factionDebrisCreated then
                local elapsed = currentTime - effect.startTime

                -- Create faction debris after 0.4 seconds (when main explosion peaks)
                if elapsed > 0.4 then
                    effect.factionDebrisCreated = true

                    -- UNIVERSAL WHITE-TO-WHITISH COLOR PROGRESSION (same for all units)
                    local universalColors = {
                        {1.0, 1.0, 1.0, 1.0},     -- Pure white start
                        {0.95, 0.95, 0.95, 0.9},  -- Very light gray
                        {0.9, 0.9, 0.9, 0.8},     -- Light gray
                        {0.85, 0.85, 0.85, 0.6},  -- Medium light gray
                        {0.8, 0.8, 0.8, 0.4},     -- Medium gray
                        {0.75, 0.75, 0.75, 0.0}   -- Fade to dark gray
                    }

                    -- CREATE PHYSICS-SIMULATED BOUNCING DEBRIS
                    local debrisEffect = {
                        type = "physicsDebris",
                        x = effect.x,
                        y = effect.y,
                        startTime = currentTime,
                        duration = 4.0,  -- Long duration to see bouncing
                        isFactionDebris = true,
                        factionColors = universalColors,  -- Use universal colors instead of faction-specific
                        -- CELL BOUNDARIES - debris cannot leave this area
                        cellBounds = {
                            left = effect.x - GAME.CONSTANTS.TILE_SIZE / 2,
                            right = effect.x + GAME.CONSTANTS.TILE_SIZE / 2,
                            top = effect.y - GAME.CONSTANTS.TILE_SIZE / 2,
                            bottom = effect.y + GAME.CONSTANTS.TILE_SIZE / 2
                        },
                        groundY = effect.y + GAME.CONSTANTS.TILE_SIZE / 2 - 10,  -- Ground level in cell
                        particles = {}
                    }

                    -- CREATE INDIVIDUAL PHYSICS PARTICLES
                    local numParticles = 12  -- Fewer particles for better tracking
                    for p = 1, numParticles do
                        local particle = {
                            -- POSITION (start at explosion center)
                            x = 0,  -- Relative to effect.x
                            y = 0,  -- Relative to effect.y

                            -- VELOCITY (MUCH LOWER initial upward velocity for faster falling)
                            vx = (math.random() - 0.5) * math.random(50, 100),  -- Reduced horizontal velocity
                            vy = math.random(40,100) + math.random() * 10,      -- MUCH LOWER upward velocity

                            -- PHYSICS PROPERTIES - FASTER FALLING
                            gravity = 500,     -- EVEN HIGHER gravity
                            bounce = 0.8,      -- Slightly more bouncy
                            friction = 0.88,   -- Less friction so particles bounce more

                            -- VISUAL PROPERTIES
                            size = 0.8 + math.random() * 0.4,
                            rotation = math.random() * math.pi * 2,
                            rotationSpeed = (math.random() - 0.5) * 6,

                            -- LIFECYCLE
                            life = 0.4,
                            fadeRate = 0.20,   -- Slower fade so you can see bounces longer

                            -- STATE
                            onGround = false,
                            bounceCount = 0
                        }

                        table.insert(debrisEffect.particles, particle)
                    end

                    table.insert(self.destructionEffects, debrisEffect)
                end
            end

            -- Remove if duration expired
            if currentTime - effect.startTime >= effect.duration then
                self:recycleDestructionEffect(effect)
                table.remove(self.destructionEffects, i)
            end

        elseif effect.type == "physicsDebris" then
            for p = #effect.particles, 1, -1 do
                local particle = effect.particles[p]

                -- Apply gravity
                particle.vy = particle.vy + particle.gravity * dt

                -- Update position
                particle.x = particle.x + particle.vx * dt
                particle.y = particle.y + particle.vy * dt

                -- KEEP INSIDE CELL
                local worldX = effect.x + particle.x
                local worldY = effect.y + particle.y

                -- Left/Right boundaries - bounce horizontally
                if worldX <= effect.cellBounds.left then
                    particle.x = effect.cellBounds.left - effect.x
                    particle.vx = -particle.vx * particle.bounce  -- Reverse and dampen
                elseif worldX >= effect.cellBounds.right then
                    particle.x = effect.cellBounds.right - effect.x
                    particle.vx = -particle.vx * particle.bounce  -- Reverse and dampen
                end

                -- Top boundary - bounce downward
                if worldY <= effect.cellBounds.top then
                    particle.y = effect.cellBounds.top - effect.y
                    particle.vy = -particle.vy * particle.bounce
                end

                -- GROUND BOUNCING - This is the main bouncing effect
                if worldY >= effect.groundY then
                    particle.y = effect.groundY - effect.y  -- Place on ground

                    if particle.vy > 5 then  -- Only bounce if moving fast enough
                        particle.vy = -particle.vy * particle.bounce  -- Bounce up with damping
                        particle.bounceCount = particle.bounceCount + 1

                        -- Reduce horizontal velocity on each bounce (friction)
                        particle.vx = particle.vx * particle.friction

                    else
                        -- Too slow to bounce - settle on ground
                        particle.vy = 0
                        particle.vx = particle.vx * 0.9  -- Ground friction
                        particle.onGround = true
                    end
                end

                particle.rotation = particle.rotation + particle.rotationSpeed * dt
                -- Slow down rotation over time
                particle.rotationSpeed = particle.rotationSpeed * 0.98
                -- Fade out over time
                particle.life = particle.life - particle.fadeRate * dt
                -- Remove dead particles
                if particle.life <= 0 then
                    table.remove(effect.particles, p)
                end
            end

            -- Remove if duration expired
            if currentTime - effect.startTime >= effect.duration then
                self:recycleDestructionEffect(effect)
                table.remove(self.destructionEffects, i)
            end
        end
    end
end

function playGridClass:createCommandHubScanEffect(hubRow, hubCol, scanCells)
    -- Play scan effect sound
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/SciFiNotification3.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end

    local waves = {
        {
            radius = 0,
            maxRadius = GAME.CONSTANTS.TILE_SIZE * 2.45,
            delay = -0.08,
            duration = 0.96,
            baseOpacity = 0.58,
            baseLineWidth = 2.3
        },
        {
            radius = 0,
            maxRadius = GAME.CONSTANTS.TILE_SIZE * 2.2,
            delay = 0.08,
            duration = 1.08,
            baseOpacity = 0.42,
            baseLineWidth = 1.7
        },
        {
            radius = 0,
            maxRadius = GAME.CONSTANTS.TILE_SIZE * 2.0,
            delay = 0.26,
            duration = 1.24,
            baseOpacity = 0.3,
            baseLineWidth = 1.3
        }
    }

    local maxDuration = 0
    for _, wave in ipairs(waves) do
        local waveEnd = (wave.delay or 0) + (wave.duration or 0)
        if waveEnd > maxDuration then
            maxDuration = waveEnd
        end
    end

    local effect = {
        type = "commandHubScan",
        hubRow = hubRow,
        hubCol = hubCol,
        startTime = love.timer.getTime(),
        duration = maxDuration + 0.3,
        waves = waves,
    }

    local zoomEffect = {
        hubRow = hubRow,
        hubCol = hubCol,
        startTime = love.timer.getTime(),
        duration = 0.36,
        phase = "zoomIn",
        scale = 1.0,
        maxScale = 1.08,
        minScale = 1.0
    }

    -- Store zoom effect
    if not self.commandHubZoomEffects then
        self.commandHubZoomEffects = {}
    end
    table.insert(self.commandHubZoomEffects, zoomEffect)

    -- Store the scan effect
    if not self.commandHubScanEffects then
        self.commandHubScanEffects = {}
    end
    table.insert(self.commandHubScanEffects, effect)

    return effect
end

function playGridClass:updateCommandHubZoomEffects(dt, now)
    if not self.commandHubZoomEffects then return end

    local currentTime = now or love.timer.getTime()

    for i = #self.commandHubZoomEffects, 1, -1 do
        local effect = self.commandHubZoomEffects[i]
        local elapsed = currentTime - effect.startTime
        local progress = elapsed / effect.duration

        if progress >= 1.0 then
            -- Remove completed effect and reset scale
            local hubCell = self:getCell(effect.hubRow, effect.hubCol)
            if hubCell and hubCell.unit then
                hubCell.unit.zoomScale = nil  -- Remove zoom scale
            end
            table.remove(self.commandHubZoomEffects, i)
        else
            -- TWO PHASES ONLY - NO HOLD
            if progress < 0.5 then
                -- ZOOM IN phase (0% to 50% of duration)
                effect.phase = "zoomIn"
                local zoomProgress = progress / 0.5  -- 0 to 1 over first half
                local easedProgress = 1 - (1 - zoomProgress) * (1 - zoomProgress)  -- Ease out
                effect.scale = effect.minScale + (effect.maxScale - effect.minScale) * easedProgress

            else
                -- ZOOM OUT phase (50% to 100% of duration)
                effect.phase = "zoomOut"
                local zoomProgress = (progress - 0.5) / 0.5  -- 0 to 1 over second half
                local easedProgress = zoomProgress * zoomProgress  -- Ease in
                effect.scale = effect.maxScale - (effect.maxScale - effect.minScale) * easedProgress
            end

            -- Apply scale to the Commandant unit
            local hubCell = self:getCell(effect.hubRow, effect.hubCol)
            if hubCell and hubCell.unit then
                hubCell.unit.zoomScale = effect.scale
            end
        end
    end
end

function playGridClass:updateCommandHubScanEffects(dt, now)
    if not self.commandHubScanEffects then return end

    local currentTime = now or love.timer.getTime()

    for i = #self.commandHubScanEffects, 1, -1 do
        local effect = self.commandHubScanEffects[i]
        local elapsed = currentTime - effect.startTime
        local progress = elapsed / effect.duration

        if progress >= 1.0 then
            -- Remove completed effect
            table.remove(self.commandHubScanEffects, i)
        else
            -- Update multiple waves with different speeds
            for _, wave in ipairs(effect.waves) do
                local delay = wave.delay or 0
                local waveElapsed = elapsed - delay

                if waveElapsed >= 0 then
                    local waveDuration = math.max(0.001, wave.duration or effect.duration)
                    local rawProgress = math.min(1.0, waveElapsed / waveDuration)
                    local easedProgress = self:easeInOutCubic(rawProgress)

                    wave.radius = wave.maxRadius * easedProgress

                    local falloff = (1 - rawProgress)
                    wave.currentOpacity = (wave.baseOpacity or 0.4) * (falloff ^ 1.3)
                    wave.currentLineWidth = (wave.baseLineWidth or 1.6) * (0.35 + 0.65 * (1 - easedProgress))
                    wave.trailingRadius = math.max(0, wave.radius - (GAME.CONSTANTS.TILE_SIZE * (0.75 + 0.1 * easedProgress)))
                else
                    wave.radius = 0
                    wave.currentOpacity = 0
                    wave.currentLineWidth = wave.baseLineWidth or 1.6
                    wave.trailingRadius = 0
                end
            end
        end
    end
end

function playGridClass:drawCommandHubScanEffects()
    if not self.commandHubScanEffects then return end

    for _, effect in ipairs(self.commandHubScanEffects) do
        local hubCell = self:getCell(effect.hubRow, effect.hubCol)
        if hubCell then
            local hubCenterX = hubCell.x + GAME.CONSTANTS.TILE_SIZE / 2
            local hubCenterY = hubCell.y + GAME.CONSTANTS.TILE_SIZE / 2

            local maxRadius = 0
            for _, wave in ipairs(effect.waves) do
                if wave.maxRadius and wave.maxRadius > maxRadius then
                    maxRadius = wave.maxRadius
                end
            end
            if not self:isRectVisible(
                    hubCenterX - maxRadius,
                    hubCenterY - maxRadius,
                    hubCenterX + maxRadius,
                    hubCenterY + maxRadius,
                    GAME.CONSTANTS.TILE_SIZE) then
                goto continueCommandHubScanEffect
            end

            -- Draw multiple expanding sonar waves
            for _, wave in ipairs(effect.waves) do
                if wave.radius > 0 and (wave.currentOpacity or 0) > 0 then
                    love.graphics.setColor(0.72, 0.86, 0.98, wave.currentOpacity)
                    love.graphics.setLineWidth(wave.currentLineWidth or 1.6)
                    love.graphics.circle("line", hubCenterX, hubCenterY, wave.radius)

                    if wave.trailingRadius and wave.trailingRadius > 12 then
                        local trailingOpacity = (wave.currentOpacity or 0) * 0.55
                        love.graphics.setColor(0.58, 0.75, 0.95, trailingOpacity)
                        love.graphics.setLineWidth((wave.currentLineWidth or 1.6) * 0.55)
                        love.graphics.circle("line", hubCenterX, hubCenterY, wave.trailingRadius)
                    end
                end
            end

            -- Very subtle hub center pulse - white
            local pulseSize = 5 + 1.5 * math.sin(love.timer.getTime() * 4) -- Smaller pulse
            love.graphics.setColor(0.7, 0.7, 0.7, 0.3) -- More subtle center pulse
            love.graphics.setLineWidth(1)
            love.graphics.circle("line", hubCenterX, hubCenterY, pulseSize)

            love.graphics.setLineWidth(1)
        end

        ::continueCommandHubScanEffect::
    end

    -- Reset graphics state
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:drawDestructionEffects()
    for _, effect in ipairs(self.destructionEffects) do
        do
            local visible = true
            if effect.cellBounds then
                local bounds = effect.cellBounds
                visible = self:isRectVisible(bounds.left, bounds.top, bounds.right, bounds.bottom, GAME.CONSTANTS.TILE_SIZE)
            else
                local margin = GAME.CONSTANTS.TILE_SIZE
                visible = self:isRectVisible(effect.x - margin, effect.y - margin, effect.x + margin, effect.y + margin, margin)
            end
            if not visible then
                goto continueDestructionEffect
            end
        end

        if effect.type == "particles" then
            -- Draw simple particle system (main fountain effect)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(effect.system, effect.x, effect.y)

        elseif effect.type == "physicsDebris" then
            -- Draw physics-simulated bouncing debris
            for _, particle in ipairs(effect.particles) do
                -- Calculate world position
                local worldX = effect.x + particle.x
                local worldY = effect.y + particle.y

                -- Determine faction color based on life remaining
                local colorIndex = math.ceil((1 - particle.life) * #effect.factionColors)
                colorIndex = math.max(1, math.min(#effect.factionColors, colorIndex))
                local color = effect.factionColors[colorIndex]

                -- Draw particle with faction color and life-based alpha
                love.graphics.setColor(color[1], color[2], color[3], color[4] * particle.life)

                -- Draw as rotated square (debris piece)
                love.graphics.push()
                love.graphics.translate(worldX, worldY)
                love.graphics.rotate(particle.rotation)
                love.graphics.rectangle("fill", 
                    -particle.size * 2, -particle.size * 2, 
                    particle.size * 4, particle.size * 4)
                love.graphics.pop()
            end

        elseif effect.type == "explosion" then
            -- Keep old explosion code as fallback (if any old effects still exist)
            -- Render explosion to canvas first
            love.graphics.setCanvas(effect.canvas)
            love.graphics.clear(0, 0, 0, 0)

            -- Set up shader
            love.graphics.setShader(self.explosionShader)

            -- Send shader parameters
            self.explosionShader:send("time", effect.timeElapsed or 0)
            self.explosionShader:send("center", {128, 128}) -- Canvas center
            self.explosionShader:send("intensity", effect.intensity or 1.0)
            self.explosionShader:send("playerColor", effect.playerColor)

            -- Draw full canvas rectangle to trigger shader
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("fill", 0, 0, 256, 256)

            -- Reset shader and canvas
            love.graphics.setShader()
            love.graphics.setCanvas()

            -- Draw the explosion canvas to screen with additive blending
            love.graphics.setBlendMode("add", "alphamultiply")
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(effect.canvas, 
                effect.x - 128, 
                effect.y - 128)

            -- Reset blend mode
            love.graphics.setBlendMode("alpha")
        end

        ::continueDestructionEffect::
    end

    -- Reset graphics state
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setBlendMode("alpha")
end

function playGridClass:drawHoverIndicator()
    if not self.mouseHoverCell then return end

    if self.selectedGridUnit and self.mouseHoverCell.row == self.selectedGridUnit.row and self.mouseHoverCell.col == self.selectedGridUnit.col then
        return
    end

    if self.highlightedCells and #self.highlightedCells > 0 then
        for _, highlightedCell in ipairs(self.highlightedCells) do
            if highlightedCell.row == self.mouseHoverCell.row and highlightedCell.col == self.mouseHoverCell.col then
                return
            end
        end
    end

    if HOVER_INDICATOR_STATE.IS_HIDDEN then
        return
    end

    local cell = self.mouseHoverCell
    local cellSize = GAME.CONSTANTS.TILE_SIZE

    -- Calculate center position of cell
    local centerX = cell.x + cellSize / 2
    local centerY = cell.y + cellSize / 2

    -- Check if this cell is already a preview cell (has possible actions)
    local isPreviewCell = self:isForcedPreviewCell(cell.row, cell.col)

    -- If it's a preview cell, DON'T draw hover indicator (preview system handles it)
    if isPreviewCell then
        return
    end

    local pointerColor = {1, 1, 1, 0.7} -- Always white
    local scale = 1.0 -- Always same scale

    local time = love.timer.getTime()
    local zoomSpeed = 1.5  -- Normal speed for regular hover
    local zoomAmount = 0.04

    -- Use smooth sine wave animation (normal speed)
    local animationScale = 0.97 + (zoomAmount / 2) * math.sin(time * zoomSpeed * math.pi * 2)

    -- Combine base scale with animation
    local finalScale = scale * animationScale

    -- Draw the selection pointer
    love.graphics.setColor(pointerColor)
    love.graphics.draw(
        self.selectionPointerImage,
        centerX, centerY,
        0, -- rotation
        finalScale, finalScale,
        self.selectionPointerImage:getWidth() / 2,  -- origin X (center)
        self.selectionPointerImage:getHeight() / 2  -- origin Y (center)
    )

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:drawActionPreviews()
    -- Always show previews, even without selected unit
    if not self.selectionPointerImage then return end

    if self.selectedGridUnit then
        local selectedCell = self:getCell(self.selectedGridUnit.row, self.selectedGridUnit.col)
        if selectedCell and selectedCell.unit then
            -- Determine unit color based on player
            local selectionColor
            if selectedCell.unit.player == 1 then
                selectionColor = {0.3, 0.7, 1.0, 0.9}  -- Blue for player 1
            elseif selectedCell.unit.player == 2 then
                selectionColor = {1.0, 0.5, 0.4, 0.9}  -- Red for player 2
            else
                selectionColor = {0.4, 0.8, 0.4, 0.9}  -- Green for neutral
            end

            -- DRAW STATIC SELECTED UNIT INDICATOR (NO ANIMATION)
            local centerX = selectedCell.x + GAME.CONSTANTS.TILE_SIZE / 2
            local centerY = selectedCell.y + GAME.CONSTANTS.TILE_SIZE / 2

            -- Draw with fixed scale (no animation)
            love.graphics.setColor(selectionColor)
            love.graphics.draw(
                self.selectionPointerImage,
                centerX, centerY,
                0, -- rotation
                1.0, 1.0, -- fixed scale (no animation)
                self.selectionPointerImage:getWidth() / 2,
                self.selectionPointerImage:getHeight() / 2
            )
        end
    end

    -- Draw forced preview cells using selection pointer
    self:drawForcedPreviewCells()

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:drawForcedPreviewCells()
    if self._setupHighlightedCells and #self._setupHighlightedCells > 0 then
        local playerNum = self.repositioningPlayer or 1
        local baseColor
        if playerNum == 1 then
            baseColor = {0.3, 0.7, 1.0, 0.7}
        elseif playerNum == 2 then
            baseColor = {1.0, 0.5, 0.4, 0.7}
        else
            baseColor = {0.4, 0.8, 0.4, 0.7}
        end

        for _, cellInfo in ipairs(self._setupHighlightedCells) do
            local isHovered = self.mouseHoverCell
                and self.mouseHoverCell.row == cellInfo.row
                and self.mouseHoverCell.col == cellInfo.col

            self:drawPreviewPointer(cellInfo.row, cellInfo.col, baseColor, 1.0, "deployment", isHovered)
        end
    end

    -- Draw movement cells
    if self._cachedPreviewDraws and self._cachedPreviewDraws.movement then
        local color = {0.3, 0.8, 0.3, 0.6}
        for _, cellInfo in ipairs(self._cachedPreviewDraws.movement) do
            local isHovered = self.mouseHoverCell and self.mouseHoverCell.row == cellInfo.row and self.mouseHoverCell.col == cellInfo.col
            self:drawPreviewPointer(cellInfo.row, cellInfo.col, color, 1.0, "movement", isHovered)
        end
    end

    -- Draw attack cells
    if self._cachedPreviewDraws and self._cachedPreviewDraws.attack then
        local color = {1.0, 0.3, 0.3, 0.6}
        for _, cellInfo in ipairs(self._cachedPreviewDraws.attack) do
            local isHovered = self.mouseHoverCell and self.mouseHoverCell.row == cellInfo.row and self.mouseHoverCell.col == cellInfo.col
            self:drawPreviewPointer(cellInfo.row, cellInfo.col, color, 1.0, "attack", isHovered)
        end
    end

    -- Draw repair cells
    if self._cachedPreviewDraws and self._cachedPreviewDraws.repair then
        local color = {1.0, 0.8, 0.2, 0.6}
        for _, cellInfo in ipairs(self._cachedPreviewDraws.repair) do
            local isHovered = self.mouseHoverCell and self.mouseHoverCell.row == cellInfo.row and self.mouseHoverCell.col == cellInfo.col
            self:drawPreviewPointer(cellInfo.row, cellInfo.col, color, 1.0, "repair", isHovered)
        end
    end

    -- Keep the existing deployment cells
    if self.forcedDeploymentCells and #self.forcedDeploymentCells > 0 then
        for i, cell in ipairs(self.forcedDeploymentCells) do
            local isHovered = self.mouseHoverCell and self.mouseHoverCell.row == cell.row and self.mouseHoverCell.col == cell.col

            local color
            if cell.player == 1 then
                color = {0.3, 0.7, 1.0, 0.7}  -- Blue for player 1
            elseif cell.player == 2 then
                color = {1.0, 0.5, 0.4, 0.7}  -- Red for player 2
            else
                color = {0.4, 0.8, 0.4, 0.7}  -- Green for neutral deployment
            end

            self:drawPreviewPointer(cell.row, cell.col, color, 1.0, "deployment", isHovered)
        end
    end
end

function playGridClass:drawPreviewPointer(row, col, color, scale, animationType, isHovered)
    local cell = self:getCell(row, col)
    if not cell then return end

    local centerX = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local centerY = cell.y + GAME.CONSTANTS.TILE_SIZE / 2

    local time = love.timer.getTime()
    local zoomSpeed = 1.5  -- Base speed for non-hovered
    local zoomAmount = 0.04

    -- Standard animation for non-hovered cells
    local animationScale = 0.97 + (zoomAmount / 2) * math.sin(time * zoomSpeed * math.pi * 2)

    -- WHEN HOVERED
    if isHovered then
        -- 1. FASTER ANIMATION SPEED
        local hoveredSpeed = 3.0
        animationScale = 0.97 + (zoomAmount / 2) * math.sin(time * hoveredSpeed * math.pi * 2)

        -- 2. LARGER SCALE when hovered
        animationScale = animationScale * 1.15  -- 15% larger when hovered

        -- 3. BRIGHTER COLOR when hovered
        local brighterColor = {
            math.min(1.0, color[1] * 1.3),  -- Increase brightness by 30%
            math.min(1.0, color[2] * 1.3),
            math.min(1.0, color[3] * 1.3),
            math.min(1.0, color[4] * 1.2)   -- Slightly more opaque
        }
        color = brighterColor
    end

    -- USE STANDARD SCALE (1.0) FOR ALL INDICATORS
    local finalScale = 1.0 * animationScale

    -- Draw the main indicator
    love.graphics.setColor(color)
    love.graphics.draw(
        self.selectionPointerImage,
        centerX, centerY,
        0,
        finalScale, finalScale,
        self.selectionPointerImage:getWidth() / 2,
        self.selectionPointerImage:getHeight() / 2
    )
end

function playGridClass:isForcedPreviewCell(row, col)
    if self._setupHighlightedMap then
        local rowMap = self._setupHighlightedMap[row]
        if rowMap and rowMap[col] then
            return true
        end
    end

    if self._cachedPreviewDraws then
        local buckets = self._cachedPreviewDraws
        if buckets.movement then
            for _, cell in ipairs(buckets.movement) do
                if cell.row == row and cell.col == col then
                    return true
                end
            end
        end

        if buckets.attack then
            for _, cell in ipairs(buckets.attack) do
                if cell.row == row and cell.col == col then
                    return true
                end
            end
        end

        if buckets.repair then
            for _, cell in ipairs(buckets.repair) do
                if cell.row == row and cell.col == col then
                    return true
                end
            end
        end
    end

    if self.forcedDeploymentCells then
        for _, cell in ipairs(self.forcedDeploymentCells) do
            if cell.row == row and cell.col == col then
                return true
            end
        end
    end

    return false
end

function playGridClass:addFloatingText(row, col, value, isRepair, soundFile)
    local cell = self:getCell(row, col)
    if not cell then return end

    -- Play sound if provided
    if soundFile and SETTINGS.AUDIO.SFX then
        soundCache.play(soundFile, {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end

    -- Calculate position (center of cell)
    local x = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local y = cell.y - (GAME.CONSTANTS.TILE_SIZE / 2) + 10

    -- Format text with sign
    local text = tostring(value)
    if isRepair then
        text = "+" .. text
    else
        text = "-" .. text
    end

    -- Set color based on type
    local color
    if isRepair then
        color = {0.1, 0.9, 0.1, 1.0} -- Bright green for repair
    else
        color = {0.9, 0.1, 0.1, 1.0} -- Bright red for damage
    end

    -- Add randomness to make multiple numbers not overlap exactly
    local offsetX = math.random(-5, 5)

    -- Add to floating texts table
    table.insert(self.floatingTexts, {
        x = x + offsetX,
        y = y,
        text = text,
        color = color,
        startTime = love.timer.getTime(),
        duration = 1.2, -- 1.2 seconds total animation
        speed = 30 -- 30 pixels per second upward
    })
end

-- Update floating texts (call in update function)
function playGridClass:updateFloatingTexts(dt, now)
    local currentTime = now or love.timer.getTime()

    -- Update and remove completed texts
    for i = #self.floatingTexts, 1, -1 do
        local text = self.floatingTexts[i]
        local elapsed = currentTime - text.startTime

        -- Move text upward
        text.y = text.y - text.speed * dt

        -- Remove if duration has elapsed
        if elapsed >= text.duration then
            table.remove(self.floatingTexts, i)
        end
    end
end

-- Draw floating texts (call in draw function)
function playGridClass:drawFloatingTexts()
    local currentTime = love.timer.getTime()

    local originalFont = love.graphics.getFont()
    love.graphics.setFont(self.damageTextFont)

    for _, text in ipairs(self.floatingTexts) do
        local elapsed = currentTime - text.startTime
        local progress = elapsed / text.duration

        -- Calculate alpha (fade out)
        local alpha = 1.0 - progress

        -- Calculate scale (start big, shrink slightly)
        local scale = 1.2 - progress * 0.5

        -- Draw shadow for better visibility
        love.graphics.setColor(0, 0, 0, alpha * 0.5)
        love.graphics.print(text.text, text.x, text.y + 2, 0, scale, scale, 10, 0)

        -- Draw the text
        love.graphics.setColor(text.color[1], text.color[2], text.color[3], alpha)
        love.graphics.print(text.text, text.x, text.y, 0, scale, scale, 10, 0)
    end

    -- Reset font
    love.graphics.setFont(originalFont)
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:applyDamageFlash(row, col, duration)
    duration = duration or 0.1 -- Default 0.1 seconds flash

    table.insert(self.damagedUnits, {
        row = row,
        col = col,
        startTime = love.timer.getTime(),
        duration = duration
    })
    self.damagedUnitLookupDirty = true
end

-- Preload all unit images at startup for better performance
function playGridClass:preloadUnitImages()
    -- Load unit images for both players
    for _, info in pairs(unitsInfo.stats) do
        -- Load player 1 image
        if info.path then
            local success, image = pcall(function()
                return love.graphics.newImage(info.path)
            end)

            if success then
                self.unitImageCache[info.path] = image
            end
        end

        -- Load player 2 image (red version)
        if info.pathRed then
            local success, image = pcall(function()
                return love.graphics.newImage(info.pathRed)
            end)

            if success then
                self.unitImageCache[info.pathRed] = image
            end
        end
    end

    -- Preload Rock variant images
    local neutralBuildingVariants = {
        "assets/sprites/NeutralBulding1_Resized.png",
        "assets/sprites/NeutralBulding2_Resized.png",
        "assets/sprites/NeutralBulding3_Resized.png",
        "assets/sprites/NeutralBulding4_Resized.png"
    }

    for _, variantPath in ipairs(neutralBuildingVariants) do
        local success, image = pcall(function()
            return love.graphics.newImage(variantPath)
        end)

        if success then
            self.unitImageCache[variantPath] = image
        end
    end
end

function playGridClass:preloadTileImages()
    -- Load grass tile images
    local tileImages = {
        TILE_PATH_EVEN_PRIMARY,
        TILE_PATH_ODD_PRIMARY,
        TILE_PATH_EVEN_SECONDARY,
        TILE_PATH_ODD_SECONDARY
    }

    for _, tilePath in ipairs(tileImages) do
        local success, image = pcall(function()
            return love.graphics.newImage(tilePath)
        end)

        if success then
            self.tileImageCache[tilePath] = image
        end
    end

    self:rebuildTileVariantCache()
end

function playGridClass:drawMouseHoverIndicator()
    -- Check if the indicator should be globally hidden
    if HOVER_INDICATOR_STATE.IS_HIDDEN then
        return
    end

    -- Check if the indicator should be forcibly hidden
    if self.forceHiddenHoverIndicator then
        return
    end

    -- Check if the indicator should be hidden due to UI navigation
    if self.uiNavigationActive or not self.mouseHoverCell then
        return
    end

    -- Update triangle rotation for animation
    self.triangleRotation = self.triangleRotation + 0.03

    -- Get cell properties
    local x = self.mouseHoverCell.x
    local y = self.mouseHoverCell.y
    local size = GAME.CONSTANTS.TILE_SIZE

    -- Determine color based on state
    local color = self.hoverIndicatorColor or {203/255, 183/255, 158/255, 0.9} -- Default color if nil
    local pulseIntensity = (math.sin(love.timer.getTime() * 4) + 1) / 2 * 0.3 + 0.7

    -- Main hover border
    love.graphics.setColor(color[1], color[2], color[3], color[4] * pulseIntensity)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", x, y, size, size)
    love.graphics.setLineWidth(1)

    -- Draw tech-styled corner accents
    local cornerSize = 6
    love.graphics.setColor(color[1], color[2], color[3], 0.8 * pulseIntensity)

    -- Top-left corner
    love.graphics.rectangle("fill", x, y, cornerSize, 2)
    love.graphics.rectangle("fill", x, y, 2, cornerSize)

    -- Top-right corner
    love.graphics.rectangle("fill", x + size - cornerSize, y, cornerSize, 2)
    love.graphics.rectangle("fill", x + size - 2, y, 2, cornerSize)

    -- Bottom-left corner
    love.graphics.rectangle("fill", x, y + size - 2, cornerSize, 2)
    love.graphics.rectangle("fill", x, y + size - cornerSize, 2, cornerSize)

    -- Bottom-right corner
    love.graphics.rectangle("fill", x + size - cornerSize, y + size - 2, cornerSize, 2)
    love.graphics.rectangle("fill", x + size - 2, y + size - cornerSize, 2, cornerSize)

    -- Draw action indicator if there is one
    if self.actionIndicatorColor then
        -- Draw inner border with action type color
        love.graphics.setColor(
            self.actionIndicatorColor[1], 
            self.actionIndicatorColor[2], 
            self.actionIndicatorColor[3], 
            self.actionIndicatorColor[4] * pulseIntensity
        )
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", x + 3, y + 3, size - 6, size - 6)
        love.graphics.setLineWidth(1)
    end
end

function playGridClass:drawUnitHealthBar(x, y, size, unit)
    if not unit or not unit.currentHp or not unit.startingHp then
        return
    end

    local currentHP = unit.currentHp
    local maxHP = unit.startingHp

    -- Horizontal health bar dimensions (BOTTOM of unit)
    local barWidth = size - 4    -- Width (almost full unit width minus padding)
    local barHeight = 4          -- Height of the horizontal bar
    local offsetX = 2            -- Left padding
    local offsetY = 2            -- Distance from bottom edge

    -- Position the health bar at the BOTTOM
    local barX = x + offsetX
    local barY = y + size - barHeight - offsetY

    -- Calculate segment dimensions
    local segmentWidth = barWidth / maxHP
    local segmentSpacing = 1
    local actualSegmentWidth = segmentWidth - segmentSpacing

    -- Draw background/border for entire health bar
    love.graphics.setColor(0.2, 0.2, 0.2, 0.8)
    love.graphics.rectangle("fill", barX - 1, barY - 1, barWidth + 2, barHeight + 2, 1)

    -- Draw each HP segment (from left to right)
    for i = 1, maxHP do
        -- Calculate position (left to right)
        local segmentX = barX + (i - 1) * segmentWidth

        -- Determine color based on HP state - ONLY 3 COLORS
        if i <= currentHP then
            if currentHP == maxHP then
                -- Full health (GREEN)
                love.graphics.setColor(0.1, 0.9, 0.2, 0.95)
            elseif currentHP == 1 then
                -- Critical health (RED) - exactly 1 HP left
                love.graphics.setColor(0.95, 0.1, 0.1, 0.95)
            else
                -- Damaged health (YELLOW) - between 1 and max HP
                love.graphics.setColor(0.9, 0.8, 0.2, 0.95)
            end

            -- Draw filled segment
            love.graphics.rectangle("fill", segmentX, barY, actualSegmentWidth, barHeight, 1)
        else
            -- Empty segment (dark)
            love.graphics.setColor(0.1, 0.1, 0.1, 0.6)
            love.graphics.rectangle("fill", segmentX, barY, actualSegmentWidth, barHeight, 1)
        end

        -- Draw segment border for definition
        love.graphics.setColor(0.4, 0.4, 0.4, 0.8)
        love.graphics.setLineWidth(0.5)
        love.graphics.rectangle("line", segmentX, barY, actualSegmentWidth, barHeight, 1)
    end

    -- Draw outer border for the entire health bar
    love.graphics.setColor(0.6, 0.6, 0.6, 0.9)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", barX, barY, barWidth, barHeight, 1)

    -- Reset graphics state
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

-- Get cell at specified position
function playGridClass:getCell(row, col)
    if self:isValidPosition(row, col) then
        return self.cells[row][col]
    end
    return nil
end

-- Check if position is within grid boundaries
function playGridClass:isValidPosition(row, col)
    return row >= 1 and row <= self.rows and col >= 1 and col <= self.cols
end

function playGridClass:isCellEmpty(row, col)
   -- Check if cell coordinates are valid
   if not self:isValidPosition(row, col) then
        return false
    end

    -- Check if the cell exists and has no unit
    if self.cells[row] and self.cells[row][col] then
        -- Return true if there's no unit in this cell
        return not self.cells[row][col].unit
    end

    return false
end

-- Place a unit on the grid with proper reference handling
function playGridClass:placeUnit(unit, row, col)
    local cell = self:getCell(row, col)
    if not cell then
        return false
    end

    if cell.unit then
        return false
    end

    -- Make a deep copy of the unit to avoid reference issues
    local unitCopy = {}
    for k, v in pairs(unit) do
        unitCopy[k] = v
    end

    if unit.name == "Commandant" then
        -- Set Commandant player property
        unitCopy.player = tonumber(unit.player)
        table.insert(self.commandHubs, {row = row, col = col, player = unitCopy.player})
    end

    -- Place the unit copy, not the original reference
    cell.unit = unitCopy

    -- Update unit's position data
    unitCopy.row = row
    unitCopy.col = col
    unitCopy.pixelX = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
    unitCopy.pixelY = cell.y + GAME.CONSTANTS.TILE_SIZE / 2

    return true
end

function playGridClass:forceShowDefenseCells(cells)
    -- Clear any previous forced highlighting
    self:clearForcedHighlightedCells()

    -- Store and highlight the cells
    self.forcedHighlightedCells = cells

    for _, cell in ipairs(cells) do
        self:highlightCell(cell.row, cell.col, {0.2, 1, 0.2}) -- Green highlight
    end
    
    -- Play preview indicator sound if we have cells to show
    if #cells > 0 then
        self:playPreviewIndicatorSound()
    end
end

-- Start repositioning a Commandant for the current player
function playGridClass:startRepositioningHub(player)
    -- Don't allow repositioning if setup is already confirmed
    if self.setupComplete[player] then
        return false
    end

    -- Find the current player's Commandant
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell.unit and cell.unit.name == "Commandant" and cell.unit.player == player then
                -- Save original position
                self.originalHubPosition = {row = row, col = col, unit = cell.unit}

                -- Save a copy of the hub unit for hologram display
                self.hubHologram = {}
                for k, v in pairs(cell.unit) do
                    self.hubHologram[k] = v
                end
                self.hubHologram.isHologram = true -- Mark as hologram for special rendering

                -- Remove from grid (temporarily)
                cell.unit = nil

                -- Set repositioning state
                self.isRepositioningHub = true
                self.repositioningPlayer = player

                -- Highlight valid cells for placement
                self:highlightSetupCells(player)

                return true
            end
        end
    end

    return false
end

function playGridClass:cancelRepositioningHub()
    if self.isRepositioningHub and self.originalHubPosition then
        -- Get the saved position
        local row = self.originalHubPosition.row
        local col = self.originalHubPosition.col
        local unit = self.originalHubPosition.unit

        -- Put the hub back
        self.cells[row][col].unit = unit

        -- Reset state
        self.isRepositioningHub = false
        self.repositioningPlayer = nil
        self.originalHubPosition = nil
        self:clearHighlightedCells()

        self:clearSetupHighlights(true)

        return true
    end

    return false
end

function playGridClass:commitRepositioningHub(newRow, newCol)
    if self.isRepositioningHub and self.originalHubPosition then
        -- Place the hub at the new location
        local success = self:placeUnit(self.originalHubPosition.unit, newRow, newCol)

        if success then
            -- Get the placed unit reference
            local cell = self:getCell(newRow, newCol)
            if cell and cell.unit then
                -- Apply the same flash effect as Rocks
                cell.unit.justPlaced = true
                cell.unit.placedTime = love.timer.getTime()
                cell.unit.materializeProgress = 0.0
                
                -- Play teleport whoosh sound when unit evocation effect starts
                self:playTeleportSound()
            end

            -- Reset state
            self.isRepositioningHub = false
            self.repositioningPlayer = nil
            self.originalHubPosition = nil
            self.hubHologram = nil  -- Clear the hologram
            self:clearHighlightedCells()
            self:clearSetupHighlights()

            return true
        end
    end

    return false
end

function playGridClass:confirmSetup(player)
    -- Make sure player is a number
    player = tonumber(player)

    if not player or (player ~= 1 and player ~= 2) then
        return false
    end

    -- Cancel any ongoing repositioning
    if self.isRepositioningHub and self.repositioningPlayer == player then
        self:cancelRepositioningHub()
    end

    -- Mark setup as complete
    self.setupComplete[player] = true

    return true
end

-- Check if a player's setup is confirmed
function playGridClass:isSetupConfirmed(player)
    player = tonumber(player)
    return self.setupComplete[player] or false
end

-- Reset setup confirmation (for starting a new game)
function playGridClass:resetSetupConfirmation()
    self.setupComplete = {
        [1] = false,
        [2] = false
    }
    return true
end

-- Remove a unit from the grid
function playGridClass:removeUnit(row, col)
    local cell = self:getCell(row, col)
    if cell and cell.unit then
        -- Special handling for Commandant
        if cell.unit.name == "Commandant" then
            -- Remove from tracking
            for i, hub in ipairs(self.commandHubs) do
                if hub.row == row and hub.col == col then
                    table.remove(self.commandHubs, i)
                    break
                end
            end
        end

        cell.unit = nil
        return true
    end
    return false
end

-- Get unit at the specified position
function playGridClass:getUnitAt(row, col)
    local cell = self:getCell(row, col)
    if cell then
        return cell.unit
    end
    return nil
end

function playGridClass:addSetupHighlight(row, col)
    if not self._setupHighlightedMap[row] then
        self._setupHighlightedMap[row] = {}
    end

    if not self._setupHighlightedMap[row][col] then
        self._setupHighlightedMap[row][col] = true
        table.insert(self._setupHighlightedCells, {row = row, col = col})
    end

    local cell = self:getCell(row, col)
    if cell then
        cell.setupHighlight = true
    end
end

function playGridClass:removeSetupHighlight(row, col)
    local rowMap = self._setupHighlightedMap[row]
    if rowMap and rowMap[col] then
        rowMap[col] = nil

        for idx = #self._setupHighlightedCells, 1, -1 do
            local info = self._setupHighlightedCells[idx]
            if info.row == row and info.col == col then
                table.remove(self._setupHighlightedCells, idx)
                break
            end
        end

        if next(rowMap) == nil then
            self._setupHighlightedMap[row] = nil
        end
    end

    local cell = self:getCell(row, col)
    if cell then
        cell.setupHighlight = false
    end
end

function playGridClass:clearSetupHighlights(preservePNGIndicators)
    for _, cellInfo in ipairs(self._setupHighlightedCells) do
        local cell = self:getCell(cellInfo.row, cellInfo.col)
        if cell then
            cell.setupHighlight = false
        end
    end

    self._setupHighlightedCells = {}
    self._setupHighlightedMap = {}

    if not preservePNGIndicators and self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    end
end

function playGridClass:setCellActionHighlight(row, col, actionType)
    local cell = self:getCell(row, col)
    if cell then
        cell.actionHighlight = actionType -- "move", "attack", "repair", "deploy"
        if actionType then
            self.hasActionHighlights = true
        end
    end
end

-- Clear all action highlights
function playGridClass:clearActionHighlights()
    if not self.hasActionHighlights then
        return
    end
    for row = 1, self.rows do
        for col = 1, self.cols do
            self.cells[row][col].actionHighlight = nil
        end
    end
    self.hasActionHighlights = false
end

-- Show repair target cells in yellow
function playGridClass:forceShowRepairCells(repairCells)
    if not self.forcedRepairCells then
        self.forcedRepairCells = {}
    end

    for _, cell in ipairs(repairCells) do
        table.insert(self.forcedRepairCells, {
            row = cell.row,
            col = cell.col,
            isRepairCell = true
        })
    end
    
    -- Play preview indicator sound if we have cells to show
    if #repairCells > 0 then
        self:playPreviewIndicatorSound()
    end
end

function playGridClass:highlightSetupCells(playerNum)

    self:clearSetupHighlights()

    -- Force player to number
    playerNum = tonumber(playerNum)

    -- Determine valid rows based on player number
    local minRow, maxRow
    if playerNum == 1 then
        minRow, maxRow = 1, 2  -- Player 1: Top rows
    else
        minRow, maxRow = self.rows - 1, self.rows  -- Player 2: Bottom rows
    end

    -- Also use player-colored highlighted cells (existing system)
    local validRows = {min = minRow, max = maxRow}
    self:highlightValidCells(validRows, nil, playerNum)

    self:forceShowCommandHubPlacements(playerNum, minRow, maxRow)
end

function playGridClass:forceShowCommandHubPlacements(playerNum, minRow, maxRow)
    -- Create the forcedDeploymentCells collection if it doesn't exist
    if not self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    else
        -- Clear previous forced cells
        self.forcedDeploymentCells = {}
    end

    -- Add all valid Commandant placement cells
    local count = 0
    for row = minRow, maxRow do
        for col = 1, self.cols do
            local isEmpty = self:isCellEmpty(row, col)

            if isEmpty then
                self:addSetupHighlight(row, col)

                table.insert(self.forcedDeploymentCells, {
                    row = row,
                    col = col,
                    player = playerNum,
                    isCommandHubPlacement = true
                })
                count = count + 1
            end
        end
    end
end

function playGridClass:forceShowCommandHubPNGIndicators(playerNum)
    -- Create the forcedDeploymentCells collection if it doesn't exist
    if not self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    else
        -- Clear previous forced cells
        self.forcedDeploymentCells = {}
    end

    -- Determine valid rows based on player number
    local minRow, maxRow
    if playerNum == 1 then
        minRow, maxRow = 1, 2  -- Player 1: Top rows
    else
        minRow, maxRow = self.rows - 1, self.rows  -- Player 2: Bottom rows
    end

    -- Add all valid Commandant placement cells
    local count = 0
    for row = minRow, maxRow do
        for col = 1, self.cols do
            if self:isCellEmpty(row, col) then
                self:addSetupHighlight(row, col)

                table.insert(self.forcedDeploymentCells, {
                    row = row,
                    col = col,
                    player = playerNum,
                    isCommandHubPlacement = true
                })
                count = count + 1
            end
        end
    end

    return count > 0
end

function playGridClass:clearCommandHubPNGIndicators()
    if self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    end
end

-- Highlight cells for movement
function playGridClass:highlightMoveCells(unit, range)
    self:clearActionHighlights()

    -- Use centralized function to get unit move range with debug printing
    range = range or unitsInfo:getUnitMoveRange(unit, "HIGHLIGHT_MOVE_CELLS")
    local startRow = unit.row
    local startCol = unit.col

    -- Highlight cells within movement range
    for row = 1, self.rows do
        for col = 1, self.cols do
            local distance = math.abs(row - startRow) + math.abs(col - startCol)
            if distance <= range and self:isCellEmpty(row, col) then
                self.cells[row][col].actionHighlight = "move"
                self.hasActionHighlights = true
            end
        end
    end
end

-- Coordinate conversion function
function playGridClass:gridToChessNotation(row, col)
    local columns = "ABCDEFGH"
    local column = string.sub(columns, col, col)
    return column .. row
end

-- Helper function to convert screen coordinates to grid coordinates
function playGridClass:screenToGridCoordinates(screenX, screenY)
    local gridX = math.floor((screenX - GAME.CONSTANTS.GRID_ORIGIN_X) / GAME.CONSTANTS.TILE_SIZE) + 1
    local gridY = math.floor((screenY - GAME.CONSTANTS.GRID_ORIGIN_Y) / GAME.CONSTANTS.TILE_SIZE) + 1

    return gridY, gridX  -- Return as row, col
end

-- Helper function to check if a point is within the grid bounds
function playGridClass:isPointInGrid(x, y)
    local inBoundsX = x >= GAME.CONSTANTS.GRID_ORIGIN_X and 
                    x < GAME.CONSTANTS.GRID_ORIGIN_X + (self.cols * GAME.CONSTANTS.TILE_SIZE)

    local inBoundsY = y >= GAME.CONSTANTS.GRID_ORIGIN_Y and 
                    y < GAME.CONSTANTS.GRID_ORIGIN_Y + (self.rows * GAME.CONSTANTS.TILE_SIZE)

    return inBoundsX and inBoundsY
end

function playGridClass:getViewBounds(padding)
    padding = padding or 0
    local left = -padding
    local top = -padding
    local right = SETTINGS.DISPLAY.WIDTH + padding
    local bottom = SETTINGS.DISPLAY.HEIGHT + padding
    return left, top, right, bottom
end

function playGridClass:isPointVisible(x, y, padding)
    local left, top, right, bottom = self:getViewBounds(padding)
    return x >= left and x <= right and y >= top and y <= bottom
end

function playGridClass:isRectVisible(minX, minY, maxX, maxY, padding)
    local left, top, right, bottom = self:getViewBounds(padding)
    return maxX >= left and minX <= right and maxY >= top and minY <= bottom
end

function playGridClass:updateAnimations(dt, now)
    local completed = {}
    local currentTime = now or love.timer.getTime()

    -- Update each animation
    for i, anim in ipairs(self.movingUnits) do
        anim.elapsed = math.min((anim.elapsed or 0) + dt, anim.duration)
        if anim.duration <= 0 then
            anim.progress = 1
        else
            anim.progress = math.min(1, anim.elapsed / anim.duration)
        end

        -- Check if animation is complete
        if anim.progress >= 1 then
            -- Execute completion callback if provided
            if anim.onComplete then
                anim.onComplete()
            end
            table.insert(completed, i)
        end
    end

    -- Remove completed animations (in reverse order to avoid index shifting)
    for i = #completed, 1, -1 do
        table.remove(self.movingUnits, completed[i])
    end

    -- Update flashing cells
    for i = #self.flashingCells, 1, -1 do
        local flash = self.flashingCells[i]
        local elapsed = currentTime - flash.startTime
        if elapsed >= flash.duration then
            -- Remove completed flash
            table.remove(self.flashingCells, i)
        end
    end

    local damagedUnitsChanged = false
    for i = #self.damagedUnits, 1, -1 do
        local damaged = self.damagedUnits[i]
        if currentTime - damaged.startTime >= damaged.duration then
            table.remove(self.damagedUnits, i)
            damagedUnitsChanged = true
        end
    end

    if damagedUnitsChanged then
        self.damagedUnitLookupDirty = true
    end

end

function playGridClass:drawFlashingCells()
    for _, flash in ipairs(self.flashingCells) do
        local cell = self:getCell(flash.row, flash.col)
        if cell then
            local elapsed = love.timer.getTime() - flash.startTime
            local alpha = 0.7 * (1 - elapsed/flash.duration)  -- Fade out

            -- Draw flash overlay on cell
            love.graphics.setColor(flash.color[1], flash.color[2], flash.color[3], alpha)
            love.graphics.rectangle("fill", cell.x, cell.y, 
                                   GAME.CONSTANTS.TILE_SIZE, GAME.CONSTANTS.TILE_SIZE)
        end
    end
end

-- UPDATE
function playGridClass:update(dt)
    local now = love.timer.getTime()
    -- Update continuous pulsing animation
    if self.pulsing and self.pulsing.active then
        self.pulsing.scale = self.pulsing.scale + (self.pulsing.direction * dt * self.pulsing.speed * 0.08)

        -- Change direction when reaching limits
        if self.pulsing.scale >= self.pulsing.maxScale then
            self.pulsing.direction = -1
        elseif self.pulsing.scale <= self.pulsing.minScale then
            self.pulsing.direction = 1
        end
    end

    self:updateBuildingPlacementEffects(dt, now)

    self:updateImpactEffects(dt, now)

    self:updateBeamEffects(dt, now)

    self:updateScreenShake(dt, now)

    self:updateFloatingTexts(dt, now)

    self:updateDestructionEffects(dt, now)

    self:updateCommandHubScanEffects(dt, now)

    self:updateCommandHubZoomEffects(dt, now)

    self:updateTeslaStrikeEffects(dt, now)

    self:updateAIDecisionEffects(dt, now)

    self:_cacheForcedPreviewCells()

end

function playGridClass:_cacheForcedPreviewCells()
    local buckets = self._cachedPreviewDraws
    if not buckets then
        buckets = {}
        self._cachedPreviewDraws = buckets
    end

    local function updateBucket(key, source)
        if source and #source > 0 then
            local bucket = buckets[key]
            if not bucket then
                bucket = {}
                buckets[key] = bucket
            else
                for i = #bucket, 1, -1 do
                    bucket[i] = nil
                end
            end

            for i, cell in ipairs(source) do
                bucket[i] = bucket[i] or {}
                bucket[i].row = cell.row
                bucket[i].col = cell.col
            end
        else
            buckets[key] = nil
        end
    end

    updateBucket("movement", self.forcedMovementCells)
    updateBucket("attack", self.forcedAttackCells)
    updateBucket("repair", self.forcedRepairCells)
end

-- Updated highlighting function with proper player parameter handling
function playGridClass:highlightValidCells(validRows, validCols, player)
    -- Initialize highlighted cells array - REPLACE, DON'T APPEND
    self.highlightedCells = {}

    -- Ensure player is explicitly a number to avoid type issues
    local playerNum = tonumber(player) or 0 -- Default to neutral when not provided

    -- Convert validRows range to explicit rows array
    local rows = {}
    if type(validRows) == "table" and validRows.min and validRows.max then
        for i = validRows.min, validRows.max do
            table.insert(rows, i)
        end
    elseif type(validRows) == "table" then
        rows = validRows
    else
        return
    end

    -- If validCols not provided, use all columns
    local cols = {}
    if not validCols then
        for i = 1, self.cols do
            table.insert(cols, i)
        end
    elseif type(validCols) == "table" and validCols.min and validCols.max then
        for i = validCols.min, validCols.max do
            table.insert(cols, i)
        end
    else
        cols = validCols
    end

    -- Mark cells as highlighted if they're valid and empty
    for _, row in ipairs(rows) do
        for _, col in ipairs(cols) do
            -- Make sure the position is valid and cell is empty
            if self:isValidPosition(row, col) and self:isCellEmpty(row, col) then
                local assignedPlayer = playerNum

                if assignedPlayer == 0 then
                    if row <= 2 then
                        assignedPlayer = 1
                    elseif row >= self.rows - 1 then
                        assignedPlayer = 2
                    end
                end

                -- Store the player number directly in the entry
                table.insert(self.highlightedCells, {
                    row = row, 
                    col = col,
                    player = assignedPlayer
                })
            end
        end
    end
end

function playGridClass:clearHighlightedCells()
    if not self.highlightedCells or next(self.highlightedCells) == nil then
        return
    end
    self.highlightedCells = {}
end

function playGridClass:clearForcedHighlightedCells(options)
    options = options or {}

    -- By default, clear all types of highlights unless specified
    if options.movementOnly then
        if not self.forcedDeploymentCells or #self.forcedDeploymentCells == 0 then
            return
        end
        self.forcedDeploymentCells = {}
    elseif options.attackOnly then
        if not self.forcedAttackCells or #self.forcedAttackCells == 0 then
            return
        end
        self.forcedAttackCells = {}
    elseif options.repairOnly then
        if not self.forcedRepairCells or #self.forcedRepairCells == 0 then
            return
        end
        self.forcedRepairCells = {}
    else
        local hasAny = (self.forcedDeploymentCells and #self.forcedDeploymentCells > 0)
            or (self.forcedAttackCells and #self.forcedAttackCells > 0)
            or (self.forcedRepairCells and #self.forcedRepairCells > 0)
            or (self.forcedMovementCells and #self.forcedMovementCells > 0)
        if not hasAny then
            return
        end
        -- Clear all
        self.forcedDeploymentCells = {}
        self.forcedAttackCells = {}
        self.forcedRepairCells = {}
        self.forcedMovementCells = {}
    end
end

function playGridClass:highlightCell(row, col, playerNum, alpha)
    if not self:isValidPosition(row, col) then return end

    alpha = alpha or 0.3
    local playerColor = {
        [1] = {0, 0, 1, alpha},  -- Blue for player 1
        [2] = {1, 0, 0, alpha}   -- Red for player 2
    }

    local color = playerColor[playerNum] or {0.5, 0.5, 0.5, alpha}

    -- Store the highlight info
    if not self.highlightedCells then
        self.highlightedCells = {}
    end

    self.highlightedCells[row .. "," .. col] = {
        row = row,
        col = col,
        color = color
    }
end

function playGridClass:forceShowMovementCells(movementCells)
    -- Create the forcedMovementCells collection if it doesn't exist
    if not self.forcedMovementCells then
        self.forcedMovementCells = {}
    end

    -- Add each movement cell to the collection
    for _, cell in ipairs(movementCells) do
        table.insert(self.forcedMovementCells, {
            row = cell.row,
            col = cell.col,
            isMovementCell = true
        })
    end
    
    -- Play preview indicator sound if we have cells to show
    if #movementCells > 0 then
        self:playPreviewIndicatorSound()
    end
end

function playGridClass:drawHighlightedCells()
    if not self.highlightedCells then
        return
    end

    -- Load selection pointer image if not cached
    if not self.selectionPointerImage then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/selectionPointer.png")
        if success then
            self.selectionPointerImage = image
        else
            return -- Exit if PNG can't load
        end
    end

    if #self.highlightedCells > 0 then
        for i, cell in ipairs(self.highlightedCells) do
            local playerVal = tonumber(cell.player)

            -- Determine PNG color based on player
            local color
            if playerVal == 1 then
                color = {0.3, 0.7, 1.0, 0.7}  -- Blue for player 1
            elseif playerVal == 2 then
                color = {1.0, 0.5, 0.4, 0.7}  -- Red for player 2
            else
                color = {0.4, 0.8, 0.4, 0.7}  -- Green for neutral
            end

            -- Check if being hovered for accelerated animation
            local isHovered = self.mouseHoverCell and self.mouseHoverCell.row == cell.row and self.mouseHoverCell.col == cell.col

            -- USE STANDARD SCALE (1.0) - same as hover indicator
            self:drawPreviewPointer(cell.row, cell.col, color, 1.0, "deployment", isHovered)
        end
    end
end

function playGridClass:forceShowDeploymentCells(row, col, playerNum)
    -- Store direct references to deployment cells that won't be affected by other code
    if not self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    else
        -- Clear previous forced cells
        self.forcedDeploymentCells = {}
    end
    
    -- Directions: up, down, left, right
    local directions = {
        {row=row-1, col=col},
        {row=row+1, col=col},
        {row=row, col=col-1},
        {row=row, col=col+1}
    }
    -- Store valid deployment cells
    local validCells = 0
    for _, pos in ipairs(directions) do
        if self:isValidPosition(pos.row, pos.col) and self:isCellEmpty(pos.row, pos.col) then
            table.insert(self.forcedDeploymentCells, {
                row = pos.row,
                col = pos.col,
                playerNum = playerNum
            })
            validCells = validCells + 1
        end
    end
    
    -- Play preview indicator sound if we have cells to show
    if validCells > 0 then
        self:playPreviewIndicatorSound()
    end
end

function playGridClass:forceShowActionsCells(moveCells)
    -- Store direct references to deployment cells that won't be affected by other code
    if not self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    else
        -- Clear previous forced cells
        self.forcedDeploymentCells = {}
    end

    -- Store valid deployment cells
    local validCells = 0
    for _, pos in ipairs(moveCells) do
        if self:isValidPosition(pos.row, pos.col) and self:isCellEmpty(pos.row, pos.col) then
            table.insert(self.forcedDeploymentCells, {
                row = pos.row,
                col = pos.col,
            })
            validCells = validCells + 1
        end
    end
    
    -- Play preview indicator sound if we have cells to show
    if validCells > 0 then
        self:playPreviewIndicatorSound()
    end
end

-- Show attack range cells in red
function playGridClass:forceShowAttackCells(attackCells)
    -- Create the forcedAttackCells collection if it doesn't exist
    if not self.forcedAttackCells then
        self.forcedAttackCells = {}
    else
        -- Only clear previous attack cells, not movement cells
        self.forcedAttackCells = {}
    end

    -- Add each attack cell to the collection
    for _, cell in ipairs(attackCells) do
        table.insert(self.forcedAttackCells, {
            row = cell.row,
            col = cell.col,
            isAttackCell = true  -- Mark as attack cell for rendering
        })
    end
    
    -- Play preview indicator sound if we have cells to show
    if #attackCells > 0 then
        self:playPreviewIndicatorSound()
    end
end

-- Draw grid background and border
function playGridClass:drawGridBackground()
    if self.backgroundShader then
        love.graphics.setShader(self.backgroundShader)
        local windowWidth, windowHeight = love.graphics.getDimensions()
        self.backgroundShader:send("time", love.timer.getTime())
        self.backgroundShader:send("resolution", {windowWidth, windowHeight})

        local gridCenterX = GAME.CONSTANTS.GRID_ORIGIN_X + GAME.CONSTANTS.GRID_WIDTH / 2
        local gridCenterY = GAME.CONSTANTS.GRID_ORIGIN_Y + GAME.CONSTANTS.GRID_HEIGHT / 2
        self.backgroundShader:send("gridCenter", {gridCenterX, gridCenterY})
        self.backgroundShader:send("gridSize", GAME.CONSTANTS.GRID_WIDTH)

        self.backgroundShader:send("displayScale", SETTINGS.DISPLAY.SCALE)
        self.backgroundShader:send("displayOffset", {SETTINGS.DISPLAY.OFFSETX, SETTINGS.DISPLAY.OFFSETY})

        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
        love.graphics.setShader()
    else
        love.graphics.setColor(45/255, 39/255, 37/255)
        love.graphics.rectangle("fill", 0, 0, SETTINGS.DISPLAY.WIDTH, SETTINGS.DISPLAY.HEIGHT)
    end

    love.graphics.setColor(46/255, 38/255, 32/255)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line",
        GAME.CONSTANTS.GRID_ORIGIN_X - 5,
        GAME.CONSTANTS.GRID_ORIGIN_Y - 5,
        self.cols * GAME.CONSTANTS.TILE_SIZE + 10,
        self.rows * GAME.CONSTANTS.TILE_SIZE + 10)

    love.graphics.setColor(108/255, 88/255, 66/255)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line",
        GAME.CONSTANTS.GRID_ORIGIN_X - 3,
        GAME.CONSTANTS.GRID_ORIGIN_Y - 3,
        self.cols * GAME.CONSTANTS.TILE_SIZE + 6,
        self.rows * GAME.CONSTANTS.TILE_SIZE + 6)

    love.graphics.setColor(79/255, 62/255, 46/255)
    love.graphics.rectangle("line",
        GAME.CONSTANTS.GRID_ORIGIN_X - 2,
        GAME.CONSTANTS.GRID_ORIGIN_Y - 2,
        self.cols * GAME.CONSTANTS.TILE_SIZE + 4,
        self.rows * GAME.CONSTANTS.TILE_SIZE + 4)

    love.graphics.setColor(46/255, 38/255, 32/255)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line",
        GAME.CONSTANTS.GRID_ORIGIN_X,
        GAME.CONSTANTS.GRID_ORIGIN_Y,
        self.cols * GAME.CONSTANTS.TILE_SIZE,
        self.rows * GAME.CONSTANTS.TILE_SIZE)
end

function playGridClass:onDisplayResized()
    GAME.CONSTANTS.GRID_ORIGIN_X = (SETTINGS.DISPLAY.WIDTH - GAME.CONSTANTS.GRID_WIDTH) / 2
    GAME.CONSTANTS.GRID_ORIGIN_Y = (SETTINGS.DISPLAY.HEIGHT - GAME.CONSTANTS.GRID_HEIGHT) / 2
    self:invalidateCoordinateLabelCache()
end

function playGridClass:drawGridCells()
    local cellSize = GAME.CONSTANTS.TILE_SIZE
    if not self.tileVariantByCell or not self.tileVariantByCell[1] then
        self:rebuildTileVariantCache()
    end

    if self.windShader then
        local currentTime = love.timer.getTime()
        self.windShader:send("time", currentTime)
        self.windShader:send("windDirection", self.windDirection or {0.7, 0.3})
        self.windShader:send("windStrength", self.windStrength or 0.8)
        love.graphics.setShader(self.windShader)
    end

    for row = 1, self.rows do
        local rowVariants = self.tileVariantByCell[row]
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            local tileImagePath = rowVariants and rowVariants[col]
            local tileImage = tileImagePath and self.tileImageCache[tileImagePath]

            if tileImage then
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.draw(tileImage, cell.x, cell.y, 0,
                    cellSize / tileImage:getWidth(),
                    cellSize / tileImage:getHeight())
            else
                -- Fallback to brown colors if images are unavailable.
                if (row + col) % 2 == 0 then
                    love.graphics.setColor(108/255, 88/255, 66/255)
                else
                    love.graphics.setColor(79/255, 62/255, 46/255)
                end
                love.graphics.rectangle("fill", cell.x, cell.y, cellSize, cellSize)
            end
        end
    end

    if self.windShader then
        love.graphics.setShader()
    end

    love.graphics.setColor(0.2, 0.3, 0.1, 0.3)
    love.graphics.setLineWidth(0.5)
    for row = 1, self.rows do
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            love.graphics.rectangle("line", cell.x, cell.y, cellSize, cellSize)
        end
    end
    love.graphics.setLineWidth(1)

    -- Keep the grid border shadow
    love.graphics.setColor(46/255, 38/255, 32/255, 0.15)
    love.graphics.setLineWidth(4)
    love.graphics.rectangle("line",
    GAME.CONSTANTS.GRID_ORIGIN_X + 3,
    GAME.CONSTANTS.GRID_ORIGIN_Y + 3,
    self.cols * GAME.CONSTANTS.TILE_SIZE - 2,
    self.rows * GAME.CONSTANTS.TILE_SIZE - 2)
    love.graphics.setLineWidth(1)
end

function playGridClass:selectUnit(row, col)
    local cell = self:getCell(row, col)
    if cell and cell.unit then
        -- Check if unit has legal actions available before allowing selection
        if self.gameRuler and self.gameRuler.unitHasLegalActions then
            local hasLegalActions = self.gameRuler:unitHasLegalActions(row, col)
            if not hasLegalActions then
                -- Unit has no legal actions, don't allow selection
                self.selectedGridUnit = nil
                return false
            end
        end
        
        -- Select the unit
        self.selectedGridUnit = {row = row, col = col}
        return true
    else
        -- Clear selection if no unit
        self.selectedGridUnit = nil
        return false
    end
end

-- Add this method to clear selection
function playGridClass:clearSelectedGridUnit()
    self.selectedGridUnit = nil
end

function playGridClass:drawStandardUnit(cell, unitColor, unitTypeText)
    local cellSize = GAME.CONSTANTS.TILE_SIZE
    local scale = cell.scale or 1.0  -- Use the scale property if provided

    -- Apply zoom scale if present (for Commandant zoom effect)
    if cell.unit and cell.unit.zoomScale then
        scale = scale * cell.unit.zoomScale
    end

    -- Determine if this unit should have idle animation
    local shouldUseIdleShader = false
    if cell.unit and not cell.unit.isHologram and not cell.isAnimating and not cell.unit.justPlaced then
        -- Only apply to player units (not Rocks or Commandant)
        local isPlayerUnit = (cell.unit.player == 1 or cell.unit.player == 2)
        local isCommandHub = (cell.unit.name == "Commandant")
        
        if isPlayerUnit and not isCommandHub then
            -- Check if unit is not selected and not in any special animation state
            local isSelected = (self.selectedGridUnit and 
                               self.selectedGridUnit.row == cell.row and 
                               self.selectedGridUnit.col == cell.col)
            local isHighlighted = false
            
            -- Check if unit is highlighted by any effect
            if self.highlightedCells then
                for _, highlightCell in ipairs(self.highlightedCells) do
                    if highlightCell.row == cell.row and highlightCell.col == cell.col then
                        isHighlighted = true
                        break
                    end
                end
            end
            
            shouldUseIdleShader = not isSelected and not isHighlighted
        end
    end

    -- Check if we have an image for this unit
    if cell.unit and cell.unit.path and self.unitImageCache[cell.unit.path] then
        local unitImage = nil
        if cell.unit.player == 1 then
            unitImage = self.unitImageCache[cell.unit.path]
        elseif cell.unit.player == 2 then
            unitImage = self.unitImageCache[cell.unit.pathRed]
        else
            unitImage = self.unitImageCache[cell.unit.path]
        end

        -- Calculate scaling to fit the cell
        local padding = cellSize * 0.01

        -- Different base scales for player units vs Rocks
        local baseScale
        if cell.unit.player == 1 or cell.unit.player == 2 then
            baseScale = 0.1  -- Scale for player units
        else
            baseScale = 0.1  -- Full scale (1.0) for Rocks
        end

        -- Apply the scale modifier (for animations)
        local actualScale = baseScale * scale

        local drawWidth = unitImage:getWidth() * actualScale
        local drawHeight = unitImage:getHeight() * actualScale

        -- Center the image in the cell
        local offsetX = cell.x + (cellSize - drawWidth) / 2

        -- Different vertical positioning for Rocks vs player units
        local offsetY
        if cell.unit.player == 1 or cell.unit.player == 2 then
            -- Player units - use standard centering with offset for "standing" appearance
            offsetY = (cell.y - 15) + (cellSize - drawHeight) / 2
        else
            -- Rocks - place at the bottom of tile for proper grounding
            offsetY = cell.y + (cellSize - drawHeight) - padding - 2
        end

        -- DRAW SHADOW FIRST - but ONLY for static units, not for animated units
        -- This prevents duplicate shadows during movement
        if not cell.unit.isHologram and not cell.isAnimating then
            local unitName = resolveShadowUnitName(cell.unit)
            local config = STATIC_SHADOW_CONFIGS[unitName]
            if not config then
                if cell.unit.player == 1 or cell.unit.player == 2 then
                    config = DEFAULT_STATIC_PLAYER_SHADOW
                else
                    config = DEFAULT_STATIC_NEUTRAL_SHADOW
                end
            end

            -- Calculate shadow dimensions
            local shadowWidth = drawWidth * config.widthRatio
            local shadowHeight = shadowWidth * config.heightRatio

            -- Position shadow directly under the unit's center, at the bottom of the cell
            local shadowX = offsetX + (drawWidth * (config.xOffsetRatio or 0.5)) + (config.xOffsetBias or 0)
            local shadowY = cell.y + cellSize + (config.yOffset or -28)

            -- Draw elliptical shadow centered under the unit
            love.graphics.setColor(0, 0, 0, config.opacity)
            love.graphics.ellipse("fill", shadowX, shadowY, shadowWidth/2, shadowHeight/2)
        end

        -- Apply appropriate shader based on unit state
        if cell.unit.isHologram then
            -- Use the hologram shader we created earlier
            if self.hologramShader then
                -- Send time parameter to shader for animation
                self.hologramShader:send("time", love.timer.getTime())
                -- Apply the shader
                love.graphics.setShader(self.hologramShader)
            else
                -- Fallback if shader not available: use simple color modification
                love.graphics.setColor(unitColor[1], unitColor[2], unitColor[3], 0.7)
            end
        else
            -- For normal units, use the provided color
            love.graphics.setColor(unitColor[1], unitColor[2], unitColor[3], unitColor[4] or 1)
        end

        -- Reset color to white for normal unit drawing (unless using shaders)
        if not cell.unit.isHologram then
            love.graphics.setColor(1, 1, 1, 1)
        end

        -- Apply matrix transformations for idle animation
        if shouldUseIdleShader then
            self:applyIdleMatrixTransformation(cell, offsetX, offsetY, drawWidth, drawHeight, actualScale)
        end

        -- Draw the unit image with proper positioning
        local finalOffsetY = offsetY - 20 * actualScale
        if cell.unit.player == 1 or cell.unit.player == 2 then
            -- Player units - apply slight vertical offset for "standing" appearance
            love.graphics.draw(unitImage, offsetX, finalOffsetY, 0, actualScale, actualScale)
        else
            -- Rocks - draw with bottom-centered positioning
            love.graphics.draw(unitImage, offsetX, finalOffsetY, 0, actualScale, actualScale)
        end

        -- Reset transformations if idle animation was applied
        if shouldUseIdleShader then
            love.graphics.pop()
        end

        -- HEALTH BAR VISIBILITY CONTROL
        local showHealthBar = false

        -- Check if unit is being hovered
        if self.mouseHoverCell and 
           self.mouseHoverCell.row == cell.row and 
           self.mouseHoverCell.col == cell.col and
           cell.unit then
            showHealthBar = true
        end

        -- Check if unit is a target of an action
        if self.forcedAttackCells and #self.forcedAttackCells > 0 then
            for _, attackCell in ipairs(self.forcedAttackCells) do
                if attackCell.row == cell.row and attackCell.col == cell.col then
                    showHealthBar = true
                    break
                end
            end
        end

        -- Check if unit is a target of repair
        if self.forcedRepairCells and #self.forcedRepairCells > 0 then
            for _, repairCell in ipairs(self.forcedRepairCells) do
                if repairCell.row == cell.row and repairCell.col == cell.col then
                    showHealthBar = true
                    break
                end
            end
        end

        -- Draw health bar only if conditions are met
        if showHealthBar and cell.unit.currentHp and cell.unit.startingHp and 
           not cell.unit.isHologram and not cell.unit.justPlaced then
            self:drawUnitHealthBar(cell.x, cell.y, cellSize, cell.unit)
        end

        if cell.unit and 
            not cell.unit.isHologram and 
            not cell.unit.justPlaced and 
            not cell.unit.hasActed and                    -- Unit hasn't acted (no ZZZ)
            not cell.unit.isAnimating and                 -- Unit is not currently animating
            cell.unit.name ~= "Commandant" and           -- Not a Commandant
            (cell.unit.player == 1 or cell.unit.player == 2) and  -- Not Rock
            cell.unit.player == self.gameRuler.currentPlayer and   -- ONLY current player's units
            self.gameRuler.currentPhase == "turn" and              -- During turn phase
            self.gameRuler.currentTurnPhase == "actions" then      -- During actions phase
                self:drawUnitActionIndicators(cell.x, cell.y, cellSize, cell.unit)
        end

        -- Draw "acted" indicator if unit has acted
        if cell.unit.hasActed then
            self:drawUnitActedIndicator(cell.x, cell.y, cellSize, cell.unit.player)
        end
    end

    -- Reset shader if hologram shader was used
    if cell.unit.isHologram and self.hologramShader then
        love.graphics.setShader()
    end

    -- Always reset color state
    love.graphics.setColor(1, 1, 1, 1)
end

-- Matrix transformation-based idle animation for units
function playGridClass:applyIdleMatrixTransformation(cell, offsetX, offsetY, drawWidth, drawHeight, actualScale)
    local currentTime = love.timer.getTime()
    
    -- Calculate unit center for transformation origin
    local centerX = offsetX + drawWidth / 2
    local centerY = offsetY + drawHeight / 2 - 20 * actualScale
    
    -- Determine unit type for different animation styles
    local unitType = "ground" -- Default
    if cell.unit.name == "Wingstalker" or cell.unit.name == "Cloudstriker" or cell.unit.name == "Healer" then
        unitType = "flying"
    elseif cell.unit.name == "Commandant" or cell.unit.name == "Artillery" then
        unitType = "special"
    end
    
    -- Create unique seed for this unit based on position
    local seed = cell.row * 13 + cell.col * 7
    local timeOffset = seed * 0.3 -- Stagger animations
    local animTime = currentTime + timeOffset
    
    -- Push transformation matrix
    love.graphics.push()
    
    -- Move to unit center for rotation/scaling
    love.graphics.translate(centerX, centerY)
    
    -- Apply different transformations based on unit type (subtle)
    if unitType == "flying" then
        -- Flying units: gentle hovering motion with slight rotation
        local hoverY = math.sin(animTime * 1.2) * 2.0 -- Vertical hover
        local hoverX = math.sin(animTime * 0.8) * 1.0 -- Slight horizontal drift
        local rotation = math.sin(animTime * 0.6) * 0.03 -- Gentle rotation (radians)
        local scale = 1.0 + math.sin(animTime * 1.5) * 0.02 -- Subtle breathing scale
        
        love.graphics.rotate(rotation)
        love.graphics.scale(scale, scale)
        love.graphics.translate(hoverX, hoverY)
        
    elseif unitType == "special" then
        -- Special units: Artillery only (Commandant excluded)
        local pulseScale = 1.0 + math.sin(animTime * 0.9) * 0.025
        local rotation = math.sin(animTime * 0.4) * 0.02
        local energyShift = math.sin(animTime * 1.8) * 0.8
        
        love.graphics.rotate(rotation)
        love.graphics.scale(pulseScale, pulseScale)
        love.graphics.translate(energyShift, 0)
        
    else
        -- Ground units: subtle breathing and micro-movements
        local breatheScale = 1.0 + math.sin(animTime * 0.7) * 0.015
        local microX = math.sin(animTime * 1.1) * 0.5
        local microY = math.sin(animTime * 0.9) * 0.3
        local tinyRotation = math.sin(animTime * 0.5) * 0.01
        
        love.graphics.rotate(tinyRotation)
        love.graphics.scale(breatheScale, breatheScale)
        love.graphics.translate(microX, microY)
    end
    
    -- Move back to drawing position
    love.graphics.translate(-centerX, -centerY)
end

-- Add this easing function for smoother movement
function playGridClass:easeInOutQuad(t)
    if t < 0.5 then
        return 2 * t * t
    else
        return 1 - (-2 * t + 2)^2 / 2
    end
end

function playGridClass:easeOutQuad(t)
    return -1 * t * (t - 2)
end

function playGridClass:easeIn(t)
    -- Cubic ease-in function: starts slow, ends fast
    return t * t * t
end

function playGridClass:calculateArcPosition(startX, startY, endX, endY, progress, arcHeight)
    -- Linear interpolation for X position
    local x = startX + (endX - startX) * progress

    -- Parabolic arc for Y position (rises up then comes back down)
    -- The formula creates a parabola that peaks at progress=0.5
    local arcProgress = 4 * progress * (1 - progress)
    local y = startY + (endY - startY) * progress - arcHeight * arcProgress

    return x, y
end

function playGridClass:createImpactEffect(x, y, unitType)
    -- Play dust particle sound
    if SETTINGS.AUDIO.SFX then
        soundCache.play("assets/audio/Popup4b.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME
        })
    end

    -- Create a circular particle image if we haven't already
    if not self.circleParticleImage then
        local particleCanvas = love.graphics.newCanvas(8, 8)
        love.graphics.setCanvas(particleCanvas)
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.circle("fill", 4, 4, 4)  -- Create circular particle
        love.graphics.setCanvas()
        self.circleParticleImage = love.graphics.newImage(particleCanvas:newImageData())
    end

    -- Create particle system for impact dust
    local particleSystem = love.graphics.newParticleSystem(self.circleParticleImage, 50)

    -- Configure for dust impact effect with radius emission
    particleSystem:setParticleLifetime(0.2, 0.4)      -- Short lifetime
    particleSystem:setEmissionRate(0)                 -- No continuous emission

    -- Use a larger emission area - creates particles in a circle around impact point
    particleSystem:setEmissionArea("ellipse", 35, 25, 0, false) -- Larger area, non-uniform distribution

    -- Set radial outward acceleration (push away from center)
    particleSystem:setRadialAcceleration(40, 80)      -- Strong outward push

    -- Lower initial speed since we're starting farther out
    particleSystem:setSpeed(5, 25)                    -- Reduced initial speed

    -- Other parameters
    particleSystem:setSpread(math.pi * 2)             -- 360-degree spread
    particleSystem:setLinearDamping(1.5)              -- Moderate deceleration
    particleSystem:setSizes(0.5, 0.8, 0.3)            -- Size progression
    particleSystem:setSizeVariation(0.4)              -- Size variation

    -- Whiter, more visible colors with faster fade-out
    local dustColors
    if unitType == "mech" then
        -- Mech dust - whiter
        dustColors = {
            {0.95, 0.95, 0.95, 0.6},  -- Nearly white, more transparent
            {0.9, 0.9, 0.9, 0.3},     -- Light gray, very transparent
            {0.85, 0.85, 0.85, 0.0}   -- Quick fade out
        }
    else
        -- Buildings - light tan
        dustColors = {
            {0.98, 0.95, 0.9, 0.6},   -- Very light tan, more transparent
            {0.95, 0.9, 0.85, 0.3},   -- Light tan, very transparent
            {0.9, 0.85, 0.8, 0.0}     -- Quick fade out
        }
    end

    -- Apply colors
    particleSystem:setColors(
        dustColors[1][1], dustColors[1][2], dustColors[1][3], dustColors[1][4],
        dustColors[2][1], dustColors[2][2], dustColors[2][3], dustColors[2][4],
        dustColors[3][1], dustColors[3][2], dustColors[3][3], dustColors[3][4]
    )

    -- Add slight rotation for more natural look
    particleSystem:setRotation(0, math.pi*2)
    particleSystem:setSpin(0.5, 2)

    -- Emit a burst of particles
    particleSystem:emit(50)

    -- Create the impact effect record
    local effect = {
        x = x,
        y = y,
        system = particleSystem,
        startTime = love.timer.getTime(),
        duration = 0.5  -- Slightly shorter duration
    }

    -- Add to active effects
    table.insert(self.impactEffects, effect)

    return effect
end

function playGridClass:drawImpactEffects()
    for _, effect in ipairs(self.impactEffects) do
        if effect.type == "shader" then
            -- Draw shader-based effect
            local elapsed = love.timer.getTime() - effect.startTime

            -- Set shader parameters
            self.impactShader:send("time", elapsed)
            self.impactShader:send("position", {effect.x, effect.y})
            self.impactShader:send("radius", effect.radius)
            -- Remove this line that's causing the error:
            -- self.impactShader:send("maxRadius", effect.maxRadius)
            self.impactShader:send("unitType", effect.unitType)

            -- Draw to canvas first for proper blending
            love.graphics.setCanvas(effect.canvas)
            love.graphics.clear(0, 0, 0, 0)
            love.graphics.setShader(self.impactShader)

            -- Draw a quad covering the entire effect area
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.rectangle("fill", 0, 0, effect.canvas:getWidth(), effect.canvas:getHeight())

            -- Reset shader and canvas
            love.graphics.setShader()
            love.graphics.setCanvas()

            -- Draw canvas to screen with proper positioning
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.draw(effect.canvas, 
                effect.x - effect.canvas:getWidth()/2, 
                effect.y - effect.canvas:getHeight()/2)
            love.graphics.setBlendMode("alpha")
        else
            -- Draw existing particle-based effects
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.draw(effect.system, effect.x, effect.y - 10)
        end
    end

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:updateImpactEffects(dt, now)
    local currentTime = now or love.timer.getTime()

    for i = #self.impactEffects, 1, -1 do
        local effect = self.impactEffects[i]

        if effect.type == "shader" then
            -- Update shader effect
            local elapsed = currentTime - effect.startTime

            -- Calculate current radius using easing
            local progress = math.min(1.0, elapsed / effect.duration)
            local easedProgress = 1 - (1 - progress) * (1 - progress)  -- Quadratic ease-out
            effect.radius = effect.maxRadius * easedProgress

            -- Remove if duration expired
            if elapsed >= effect.duration then
                -- Free canvas memory before removing
                effect.canvas:release()
                table.remove(self.impactEffects, i)
            end
        else
            -- Handle existing particle-based effects
            effect.system:update(dt)
            if currentTime - effect.startTime >= effect.duration then
                table.remove(self.impactEffects, i)
            end
        end
    end
end

function playGridClass:drawUnits()
    self:rebuildDamagedUnitLookup()
    local damagedLookup = self.damagedUnitLookup or {}

    -- Draw all static units on the grid
    for row = 1, self.rows do
        local damagedRow = damagedLookup[row]
        for col = 1, self.cols do
            local cell = self.cells[row][col]
            if cell and cell.unit and not cell.unit.isAnimating then
                -- Get appropriate unit color based on player
                local playerNum = cell.unit.player or 0
                local unitColor = UNIT_COLORS[playerNum] or {0.5, 0.5, 0.5, 0.9}

                -- Get unit shortName
                local unitTypeText = ""
                if cell.unit.shortName then
                    unitTypeText = cell.unit.shortName
                elseif cell.unit.name then
                    unitTypeText = cell.unit.name:sub(1, 2)
                end

                -- Apply white shader if the unit is flashing from damage
                local isFlashing = damagedRow and damagedRow[col] or false

                if isFlashing then
                    love.graphics.setShader(self.whiteShader)
                end

                if cell.unit.justPlaced then
                    -- Calculate progress for materialization effect
                    local currentTime = love.timer.getTime()
                    local elapsedTime = currentTime - cell.unit.placedTime
                    local materializeDuration = 0.8  -- 0.8 seconds to fully materialize

                    -- Update the progress (clamped from 0 to 1)
                    cell.unit.materializeProgress = math.min(1.0, elapsedTime / materializeDuration)

                    -- Handle cleanup when effect completes
                    if elapsedTime >= materializeDuration then
                        -- Effect is done, remove the flag
                        cell.unit.justPlaced = nil
                        -- Draw normally
                        self:drawStandardUnit(cell, unitColor, unitTypeText)
                    else
                        -- Apply the shader - with better error handling
                        if self.buildingMaterializeShader then
                            -- Set shader parameter directly
                            self.buildingMaterializeShader:send("progress", cell.unit.materializeProgress)

                            -- Apply shader
                            love.graphics.setShader(self.buildingMaterializeShader)

                            -- Draw the unit
                            self:drawStandardUnit(cell, unitColor, unitTypeText)

                            -- Reset shader immediately
                            love.graphics.setShader()
                        else
                            -- Fallback if shader not available
                            self:drawStandardUnit(cell, unitColor, unitTypeText)
                        end
                    end
                else
                    -- Normal unit drawing
                    self:drawStandardUnit(cell, unitColor, unitTypeText)
                end

                if isFlashing then
                    love.graphics.setShader()
                end
            end
        end
    end

    -- Draw moving units (units being animated)
    for _, anim in ipairs(self.movingUnits) do
        -- Calculate interpolated position
        local startX = GAME.CONSTANTS.GRID_ORIGIN_X + (anim.fromCol - 1) * GAME.CONSTANTS.TILE_SIZE
        local startY = GAME.CONSTANTS.GRID_ORIGIN_Y + (anim.fromRow - 1) * GAME.CONSTANTS.TILE_SIZE
        local endX = GAME.CONSTANTS.GRID_ORIGIN_X + (anim.toCol - 1) * GAME.CONSTANTS.TILE_SIZE
        local endY = GAME.CONSTANTS.GRID_ORIGIN_Y + (anim.toRow - 1) * GAME.CONSTANTS.TILE_SIZE
        local cellSize = GAME.CONSTANTS.TILE_SIZE

        local x, y, arcProgress

        if anim.useLinearMovement then
            -- LINEAR MOVEMENT for recoil effects (keep linear timing)
            local t = anim.progress  -- Use linear progress directly
            x = startX + (endX - startX) * t
            y = startY + (endY - startY) * t
            arcProgress = 0  -- No arc, so no scaling
        else
            -- ARC MOVEMENT for normal unit movement (NEW EASING)
            local t = self:easeInOutCubic(anim.progress)  -- Use the new easing function
            local arcHeight = anim.arcHeight or (cellSize * 0.5)
            x, y = self:calculateArcPosition(startX, startY, endX, endY, t, arcHeight)
            arcProgress = 4 * t * (1 - t)  -- Calculate arc progress for scaling
        end

        -- Create a temporary cell to draw the unit
        local tempCell = {
            x = x,
            y = y,
            unit = anim.unit,
            row = math.floor(anim.fromRow + (anim.toRow - anim.fromRow) * anim.progress),
            col = math.floor(anim.fromCol + (anim.toCol - anim.fromCol) * anim.progress),
            scale = anim.useLinearMovement and 1.0 or (1 + 0.2 * arcProgress),  -- No scaling for linear movement
            isAnimating = true  -- Flag to prevent static shadow drawing
        }

        -- DRAW ANIMATED SHADOW - PERSONALIZED FOR EACH UNIT TYPE
        if not anim.unit.isHologram then
            -- Get unit dimensions for shadow sizing
            local unitBaseScale = (anim.unit.player == 1 or anim.unit.player == 2) and 0.1 or 1.0
            local actualScale = unitBaseScale * tempCell.scale

            -- Estimate image dimensions
            local unitImage = nil
            if anim.unit.player == 1 then
                unitImage = self.unitImageCache[anim.unit.path]
            elseif anim.unit.player == 2 then
                unitImage = self.unitImageCache[anim.unit.pathRed]
            else
                unitImage = self.unitImageCache[anim.unit.path]
            end

            local drawWidth = unitImage:getWidth() * actualScale

            -- Get unit name and select appropriate shadow config
            local unitName = resolveShadowUnitName(anim.unit)
            local config = MOVING_SHADOW_CONFIGS[unitName]

            -- Fallback to default player/neutral config if unit not found
            if not config then
                if anim.unit.player == 1 or anim.unit.player == 2 then
                    config = DEFAULT_MOVING_PLAYER_SHADOW
                else
                    config = DEFAULT_MOVING_NEUTRAL_SHADOW
                end
            end

            -- Shadow follows ground path - use same easing as unit sprite for synchronization
            local shadowProgress
            if anim.useLinearMovement then
                shadowProgress = anim.progress  -- Linear movement uses direct progress
            else
                shadowProgress = self:easeInOutCubic(anim.progress)  -- Arc movement uses eased progress
            end
            
            local shadowX = startX + (endX - startX) * shadowProgress + cellSize/2
            local shadowY = startY + (endY - startY) * shadowProgress + cellSize + config.yOffset

            -- Shadow behavior based on movement type
            local shadowShrink, shadowOpacity
            if anim.useLinearMovement then
                -- For linear movement (recoil), keep shadow constant
                shadowShrink = 1.0
                shadowOpacity = config.opacity
            else
                -- For arc movement, shadow shrinks as unit moves higher
                shadowShrink = 1 - arcProgress * 0.7
                shadowOpacity = config.opacity * shadowShrink
            end

            -- Use personalized shadow dimensions with movement adjustments
            local shadowWidth = drawWidth * config.widthRatio * shadowShrink
            local shadowHeight = shadowWidth * config.heightRatio * shadowShrink

            -- Draw the personalized animated shadow
            love.graphics.setColor(0, 0, 0, shadowOpacity)
            love.graphics.ellipse("fill", shadowX, shadowY, shadowWidth/2, shadowHeight/2)
        end

        -- Get unit color based on player
        local playerNum = anim.unit.player or 0
        local unitColor = UNIT_COLORS[playerNum] or {0.5, 0.5, 0.5, 0.9}

        -- Get unit shortName
        local unitTypeText = ""
        if anim.unit.shortName then
            unitTypeText = anim.unit.shortName
        elseif anim.unit.name then
            unitTypeText = anim.unit.name:sub(1, 2)
        end

        -- Draw the moving unit
        self:drawStandardUnit(tempCell, unitColor, unitTypeText)

        -- Create landing impact effect only for arc movement (not linear recoil)
        if not anim.useLinearMovement and anim.progress > 0.95 and not anim.landingEffectCreated then
            -- Only create effect once per animation
            anim.landingEffectCreated = true

            -- Calculate landing position
            local landingX = endX + cellSize/2
            local landingY = endY + cellSize - 15

            -- Determine unit type (mech vs building)
            local unitType = (anim.unit.player == 1 or anim.unit.player == 2) and "mech" or "building"

            -- Create dust impact effect at landing position
            self:createImpactEffect(landingX, landingY, unitType)
        end
    end
end

-- Draw coordinate labels
function playGridClass:drawCoordinateLabels()
    -- Draw these labels directly; the cached canvas can drift out of alignment.

    -- Save current font and set coordinate font
    local defaultFont = love.graphics.getFont()
    local coordinateFont = getMonogramFont(SETTINGS.FONT.BIG_SIZE)
    love.graphics.setFont(coordinateFont)
    
    -- Use same dark brown as supply panel background (46/255, 38/255, 32/255)
    love.graphics.setColor(46/255, 38/255, 32/255)
    for col = 1, self.cols do
        local letter = string.char(64 + col)
        local xPos = GAME.CONSTANTS.GRID_ORIGIN_X + (col - 1) * GAME.CONSTANTS.TILE_SIZE + GAME.CONSTANTS.TILE_SIZE/2 - 6
        local yPos = GAME.CONSTANTS.GRID_ORIGIN_Y - 32
        love.graphics.print(letter, xPos, yPos)
    end

    for row = 1, self.rows do
        local num = tostring(row)
        local xPos = GAME.CONSTANTS.GRID_ORIGIN_X - 20
        local yPos = GAME.CONSTANTS.GRID_ORIGIN_Y + (row - 1) * GAME.CONSTANTS.TILE_SIZE + GAME.CONSTANTS.TILE_SIZE/2 - 12
        love.graphics.print(num, xPos, yPos)
    end
    
    -- Restore original font
    love.graphics.setFont(defaultFont)
end

function playGridClass:flashCell(row, col, color)
    -- Create a new flash effect
    local cell = self:getCell(row, col)
    if not cell then return end

    -- Store flash data
    table.insert(self.flashingCells, {
        row = row,
        col = col,
        color = color or {1, 0, 0},  -- Default to red
        startTime = love.timer.getTime(),
        duration = 0.5  -- Half second flash
    })

    return true
end

function playGridClass:clearAllPreviewsExceptSelected(selectedRow, selectedCol)

    -- Clear attack cells
    if self.forcedAttackCells then
        self.forcedAttackCells = {}
    end

    -- Clear repair cells  
    if self.forcedRepairCells then
        self.forcedRepairCells = {}
    end

    -- Clear deployment cells
    if self.forcedDeploymentCells then
        self.forcedDeploymentCells = {}
    end

    -- Filter movement cells to keep only the selected one
    if self.forcedMovementCells then
        local selectedCell = nil
        for _, cell in ipairs(self.forcedMovementCells) do
            if cell.row == selectedRow and cell.col == selectedCol then
                selectedCell = cell
                break
            end
        end

        -- Replace the entire array with just the selected cell (or empty if not found)
        if selectedCell then
            self.forcedMovementCells = {selectedCell}
        else
            self.forcedMovementCells = {}
        end
    end
end

function playGridClass:startMovementAnimation(fromRow, fromCol, toRow, toCol, unit, speedMultiplier, onComplete, useLinearMovement, delayPreviewClear, showSelectedCellFirst, movementProfile)
    -- Default speed multiplier to 1.0 if not provided
    speedMultiplier = speedMultiplier or 1.0

    -- Default to arc movement unless explicitly requested to use linear
    useLinearMovement = useLinearMovement or false

    -- Default delay for preview clear (0 = immediate, >0 = delayed)
    delayPreviewClear = delayPreviewClear or 0

    -- Default show selected cell first (false = normal behavior, true = AI feedback)
    showSelectedCellFirst = showSelectedCellFirst or false
    movementProfile = movementProfile or nil

    -- Create animation data
    local animation = {
        unit = unit,
        fromRow = fromRow,
        fromCol = fromCol,
        toRow = toRow, 
        toCol = toCol,
        progress = 0,
        elapsed = 0,
        startTime = love.timer.getTime(),
        useLinearMovement = useLinearMovement,  -- Store the movement type
        delayPreviewClear = delayPreviewClear,  -- Store preview clear delay
        previewClearTime = nil,  -- Will be set when delay is applied
        showSelectedCellFirst = showSelectedCellFirst,  -- Store AI feedback flag
        movementProfile = movementProfile
    }

    -- Calculate animation duration based on distance and speed
    local distance = math.abs(toRow - fromRow) + math.abs(toCol - fromCol)
    local calculatedDuration = 0
    if distance > 0 then
        calculatedDuration = distance / (self.animationSpeed * speedMultiplier)
    end
    animation.duration = math.max(calculatedDuration, self.minAnimationDuration)

    -- Only calculate arc height for arc movement
    if not useLinearMovement then
        animation.arcHeight = math.min(GAME.CONSTANTS.TILE_SIZE * 0.8, distance * GAME.CONSTANTS.TILE_SIZE * 0.4)
    end

    -- Mark the unit as currently acting and animating
    unit.isAnimating = true
    unit.isActing = true

    self:clearSelectedGridUnit()

    -- Handle AI feedback sequence
    if showSelectedCellFirst then
        -- Clear all previews except the selected movement cell
        self:clearAllPreviewsExceptSelected(toRow, toCol)

        -- Schedule clearing the selected cell after delay
        if delayPreviewClear > 0 then
            animation.previewClearTime = love.timer.getTime() + delayPreviewClear
        else
            -- Clear immediately if no delay
            self:clearForcedHighlightedCells()
        end
    else
        -- Normal behavior for player moves
        self:clearForcedHighlightedCells()
    end

    -- Add completion callback
    animation.onComplete = function()
        -- Mark the unit as no longer animating/acting
        unit.isAnimating = false
        unit.isActing = false
        self:clearForcedHighlightedCells()

        -- Set unit as having acted (for turn management)
        unit.hasActed = true

        -- Execute the provided callback if any
        if onComplete then
            onComplete()
        end
    end

    -- Store the animation
    table.insert(self.movingUnits, animation)

    -- Return the animation for reference
    return animation
end

function playGridClass:startAiMovementAnimation(fromRow, fromCol, toRow, toCol, unit, speedMultiplier, onComplete, useLinearMovement, delayPreviewClear, showSelectedCellFirst, isAIMove, actionType)
    if not unit then
        return nil
    end

    -- Convert and round coordinates to integers
    fromRow = math.floor(tonumber(fromRow) or 0)
    fromCol = math.floor(tonumber(fromCol) or 0)
    toRow = math.floor(tonumber(toRow) or 0)
    toCol = math.floor(tonumber(toCol) or 0)

    -- Add defensive checks for coordinates
    if fromRow == 0 or fromCol == 0 or toRow == 0 or toCol == 0 then
        return nil
    end

    -- Check bounds
    if toRow < 1 or toRow > self.rows or toCol < 1 or toCol > self.cols then
        return nil
    end

    if fromRow < 1 or fromRow > self.rows or fromCol < 1 or fromCol > self.cols then
        return nil
    end

    -- Clear highlights
    self:clearHighlightedCells()
    self:clearForcedHighlightedCells()
    self:clearActionHighlights()

    -- Get cells with rounded coordinates
    local fromCell = self:getCell(fromRow, fromCol)
    local toCell = self:getCell(toRow, toCol)

    if not fromCell or not toCell then
        return nil
    end

    -- Calculate center positions
    local startX = fromCell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local startY = fromCell.y + GAME.CONSTANTS.TILE_SIZE / 2
    local endX = toCell.x + GAME.CONSTANTS.TILE_SIZE / 2
    local endY = toCell.y + GAME.CONSTANTS.TILE_SIZE / 2

    -- Set unit as animating
    unit.isAnimating = true
    unit.isActing = true

    -- Calculate base duration based on distance
    local distance = math.sqrt((endX - startX)^2 + (endY - startY)^2)
    local baseDuration = 0.5 + (distance / 200) * 0.3  -- Base time + distance factor
    -- Create animation object
    local animation = {
        startTime = love.timer.getTime(),
        duration = baseDuration * (speedMultiplier or 1),
        startPos = {startX, startY},
        endPos = {endX, endY},
        unit = unit,
        fromRow = fromRow,
        fromCol = fromCol,
        toRow = toRow,
        toCol = toCol,
        progress = 0,
        useLinearMovement = useLinearMovement or false,
    }

    animation.elapsed = 0

    -- Set completion callback
    animation.onComplete = function()
        -- Mark the unit as no longer animating/acting
        unit.isAnimating = false
        unit.isActing = false

        -- Clear any remaining highlights
        self:clearForcedHighlightedCells()
        self:clearHighlightedCells()
        self:clearActionHighlights()

        -- Set unit as having acted (for turn management)
        unit.hasActed = true

        -- Execute the provided callback if any
        if onComplete then
            onComplete()
        end
    end

    -- Store the animation
    table.insert(self.movingUnits, animation)

    -- Return the animation for reference
    return animation
end

function playGridClass:addAIDecisionEffect(row, col, actionType)
    if not self.selectionPointerImage then
        local success, image = pcall(love.graphics.newImage, "assets/sprites/selectionPointer.png")
        if success then
            self.selectionPointerImage = image
        else
            return
        end
    end

    local cell = self:getCell(row, col)
    if not cell then
        return
    end

    -- Ensure pointer effect table exists
    self.aiDecisionPointerEffects = self.aiDecisionPointerEffects or {}

    local tint
    if actionType == "move" then
        tint = {0.3, 0.8, 0.3, 0.6}
    elseif actionType == "attack" then
        tint = {1.0, 0.3, 0.3, 0.6}
    elseif actionType == "repair" then
        tint = {1.0, 0.8, 0.2, 0.6}
    elseif actionType == "supply" or actionType == "deploy" then
        tint = {0.3, 0.7, 1.0, 0.7}
    else
        tint = {203/255, 183/255, 158/255, 0.9}
    end

    table.insert(self.aiDecisionPointerEffects, {
        startTime = love.timer.getTime(),
        duration = 0.32,
        cell = cell,
        startScale = 1.0,
        endScale = 1.18,
        startAlpha = 0.95,
        endAlpha = 0.0,
        animationType = actionType,
        tint = tint
    })
end
function playGridClass:updateAIDecisionEffects(dt, now)
    if not self.aiDecisionPointerEffects then
        return
    end

    local currentTime = now or love.timer.getTime()

    for i = #self.aiDecisionPointerEffects, 1, -1 do
        local effect = self.aiDecisionPointerEffects[i]
        local elapsed = currentTime - effect.startTime
        local progress = elapsed / effect.duration

        if progress >= 1 then
            table.remove(self.aiDecisionPointerEffects, i)
        else
            local eased = self:easeOutQuad(progress)
            effect.currentScale = effect.startScale + (effect.endScale - effect.startScale) * eased
            effect.currentAlpha = effect.startAlpha + (effect.endAlpha - effect.startAlpha) * progress
        end
    end
end

function playGridClass:drawAIDecisionEffects()
    if not self.aiDecisionPointerEffects or not self.selectionPointerImage then
        return
    end

    for _, effect in ipairs(self.aiDecisionPointerEffects) do
        if effect.cell and effect.currentScale and effect.currentAlpha then
            local centerX = effect.cell.x + GAME.CONSTANTS.TILE_SIZE / 2
            local centerY = effect.cell.y + GAME.CONSTANTS.TILE_SIZE / 2

            local tint = effect.tint or {1, 1, 1, 1}
            love.graphics.setColor(tint[1], tint[2], tint[3], (tint[4] or 1) * effect.currentAlpha)
            love.graphics.draw(
                self.selectionPointerImage,
                centerX,
                centerY,
                0,
                effect.currentScale,
                effect.currentScale,
                self.selectionPointerImage:getWidth() / 2,
                self.selectionPointerImage:getHeight() / 2
            )
        end
    end

    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:drawUnitActionIndicators(x, y, size, unit)
    if not unit then return end

    -- Always show 2 circles for any unit
    local maxActions = 2
    local actionsUsed = unit.actionsUsed or 0

    -- Calculate indicator position (RIGHT-MID of unit)
    local indicatorSize = 6  -- Size of each circle
    local spacing = 2        -- Space between circles
    local offsetX = 4        -- Distance from right edge
    
    -- Position for the indicators (RIGHT-MID, vertically centered)
    local startX = x + size - offsetX - indicatorSize/2  -- Right side
    local centerY = y + size / 2  -- Vertical center of the unit
    local startY = (centerY - 8) - (maxActions * indicatorSize + (maxActions - 1) * spacing) / 2 + indicatorSize/2

    -- Draw 2 circles vertically at right-mid
    for i = 1, maxActions do
        local circleX = startX
        local circleY = startY + (i - 1) * (indicatorSize + spacing)

        -- Determine if this action has been used
        local isUsed = i <= actionsUsed

        if isUsed then
            -- Filled circle for used actions - WHITE
            love.graphics.setColor(1.0, 1.0, 1.0, 0.9)  -- White color for used action
            love.graphics.circle("fill", circleX, circleY, indicatorSize / 2)

            -- Border for filled circle - slightly darker
            love.graphics.setColor(0.7, 0.7, 0.7, 0.9)  -- Light gray border
            love.graphics.setLineWidth(1)
            love.graphics.circle("line", circleX, circleY, indicatorSize / 2)
        else
            -- Empty circle for unused actions (just outline)
            love.graphics.setColor(0.7, 0.7, 0.7, 0.8)  -- Light gray border
            love.graphics.setLineWidth(1)
            love.graphics.circle("line", circleX, circleY, indicatorSize / 2)
        end
    end

    -- Reset graphics state
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:drawUnitActedIndicator(x, y, size, player)
    -- Handle when a cell object is passed instead of coordinates
    if type(x) == "table" and x.unit then
        -- Extract values from the cell
        player = x.unit.player
        size = GAME.CONSTANTS.TILE_SIZE
        y = x.y
        x = x.x
    end

    local time = love.timer.getTime() * 2

    -- Base position
    local baseX = x + size - 22
    local baseY = y + 5

    local z1X = baseX + math.sin(time) * 2
    local z1Y = baseY - math.abs(math.sin(time)) * 3
    local z2X = baseX + 8 + math.sin(time + 0.5) * 2
    local z2Y = baseY - math.abs(math.sin(time + 0.5)) * 4
    local z3X = baseX + 16 + math.sin(time + 1) * 2
    local z3Y = baseY - math.abs(math.sin(time + 1)) * 5

    -- Get player-specific color
    local textColor
    if player == 1 then
        -- Player 1: Light blue
        textColor = {142/255, 191/255, 222/255, 0.9}
    elseif player == 2 then
        -- Player 2: Light coral
        textColor = {232/255, 173/255, 165/255, 0.9}
    else
        -- Neutral: Light tan
        textColor = {203/255, 183/255, 158/255, 0.9}
    end

    -- Draw outline for each Z
    love.graphics.setColor(0, 0, 0, 0.8)
    for offsetX = -1, 1 do
        for offsetY = -1, 1 do
            if offsetX ~= 0 or offsetY ~= 0 then
                love.graphics.print("Z", z1X + offsetX, z1Y + offsetY)
                love.graphics.print("Z", z2X + offsetX, z2Y + offsetY)
                love.graphics.print("Z", z3X + offsetX, z3Y + offsetY)
            end
        end
    end

    -- Draw each Z separately with player color
    love.graphics.setColor(textColor[1], textColor[2], textColor[3], textColor[4])
    love.graphics.print("Z", z1X, z1Y)
    love.graphics.print("Z", z2X, z2Y)
    love.graphics.print("Z", z3X, z3Y)
end

local function atan2(y, x)
    -- Handle special cases
    if x == 0 then
        if y > 0 then
            return math.pi / 2
        elseif y < 0 then
            return -math.pi / 2
        else
            return 0  -- atan2(0,0) is undefined, but we'll return 0
        end
    end

    -- Calculate basic arctangent
    local angle = math.atan(y / x)

    -- Adjust based on quadrant
    if x < 0 then
        if y >= 0 then
            angle = angle + math.pi  -- Quadrant II
        else
            angle = angle - math.pi  -- Quadrant III
        end
    end

    return angle
end

function playGridClass:createBuildingPlacementEffect(row, col)
    local cell = self:getCell(row, col)
    if not cell then return end

    -- Option 1: Hologram Effect
    local effect = {
        type = "buildingPlacement",
        x = cell.x,
        y = cell.y,
        width = GAME.CONSTANTS.TILE_SIZE,
        height = GAME.CONSTANTS.TILE_SIZE,
        startTime = love.timer.getTime(),
        duration = 1.2,
        -- Store additional effect properties as needed
    }

    if not self.activeEffects then
        self.activeEffects = {}
    end

    table.insert(self.activeEffects, effect)
    return effect
end

function playGridClass:updateBuildingPlacementEffects(dt, now)
    if not self.activeEffects then return end

    local currentTime = now or love.timer.getTime()

    for i = #self.activeEffects, 1, -1 do
        local effect = self.activeEffects[i]

        if effect.type == "buildingPlacement" then
            local elapsed = currentTime - effect.startTime

            -- Remove if duration expired
            if elapsed >= effect.duration then
                table.remove(self.activeEffects, i)
            end
        end
    end
end

function playGridClass:drawBuildingPlacementEffects()
    if not self.activeEffects then return end

    for i = #self.activeEffects, 1, -1 do
        local effect = self.activeEffects[i]

        if effect.type == "buildingPlacement" then
            local elapsed = love.timer.getTime() - effect.startTime
            local progress = math.min(1.0, elapsed / effect.duration)

            -- Draw hologram materialization effect
            if progress < 0.7 then
                -- Draw hologram grid effect
                local scanlineCount = 15
                local scanlineHeight = effect.height / scanlineCount
                local scanlineOpacity = 0.3 + 0.5 * math.sin(progress * 10)

                love.graphics.setColor(0.2, 0.8, 0.9, scanlineOpacity * (0.7 - progress))
                for j = 0, scanlineCount - 1 do
                    local y = effect.y + j * scanlineHeight
                    love.graphics.line(
                        effect.x, y,
                        effect.x + effect.width, y
                    )
                end

                -- Draw outline
                love.graphics.setColor(0.2, 0.8, 0.9, 0.7 * (0.7 - progress))
                love.graphics.rectangle("line", effect.x, effect.y, effect.width, effect.height)

                -- Draw corner points
                local cornerSize = 3
                love.graphics.rectangle("fill", effect.x - cornerSize/2, effect.y - cornerSize/2, cornerSize, cornerSize)
                love.graphics.rectangle("fill", effect.x + effect.width - cornerSize/2, effect.y - cornerSize/2, cornerSize, cornerSize)
                love.graphics.rectangle("fill", effect.x - cornerSize/2, effect.y + effect.height - cornerSize/2, cornerSize, cornerSize)
                love.graphics.rectangle("fill", effect.x + effect.width - cornerSize/2, effect.y + effect.height - cornerSize/2, cornerSize, cornerSize)
            end

            -- Ground impact ripple
            if progress > 0.6 and progress < 1.0 then
                local rippleProgress = (progress - 0.6) / 0.4
                local maxRadius = effect.width * 1.5
                local rippleRadius = maxRadius * rippleProgress
                local rippleOpacity = 0.5 * (1 - rippleProgress)

                love.graphics.setColor(0.8, 0.8, 0.3, rippleOpacity)
                love.graphics.circle("line", 
                    effect.x + effect.width/2, 
                    effect.y + effect.height/2, 
                    rippleRadius)
            end

            -- Remove effect when done
            if elapsed >= effect.duration then
                table.remove(self.activeEffects, i)
            end
        end
    end

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:createBeamEffect(row, col, unitToPlace)
    -- If spawn beam effects table doesn't exist, create it
    if not self.spawnBeams then
        self.spawnBeams = {}
    end

    -- Get the target cell
    local cell = self:getCell(row, col)
    if not cell then
        return nil
    end

    -- Calculate the beam length (distance from top of screen to target cell)
    local beamLength = cell.y + GAME.CONSTANTS.TILE_SIZE - 15  -- Distance to ellipseY

    -- Calculate silhouette time based on beam length
    -- Base time of 0.25 seconds plus additional time proportional to beam length
    -- This makes longer beams take more time while keeping short beams responsive
    local baseTime = 0.25
    local lengthFactor = 0.0005  -- Adjust this value to control how much beam length affects time
    local silhouetteTime = baseTime + (beamLength * lengthFactor)

    -- Create a new beam effect with silhouette phase
    local beam = {
        row = row,
        col = col,
        startTime = love.timer.getTime(),
        duration = silhouetteTime + 0.5,  -- Total duration (silhouette time + remaining phases)
        width = 0.3,
        phase = "silhouette",
        silhouetteTime = silhouetteTime,
        expandTime = 0.2,
        holdTime = 0.2,
        fadeTime = 0.1,
        alpha = 1.0,
        silhouetteProgress = 0,
        shakeTriggered = false,
        beamGrowth = 0.0,
        unitToPlace = unitToPlace -- Store the unit to place directly in the beam effect
    }

    table.insert(self.spawnBeams, beam)
    return beam
end

function playGridClass:updateBeamEffects(dt, now)
    if not self.spawnBeams then return end

    local currentTime = now or love.timer.getTime()

    for i = #self.spawnBeams, 1, -1 do
        local beam = self.spawnBeams[i]
        local elapsed = currentTime - beam.startTime

        -- Animation phases
        if beam.phase == "silhouette" then
            -- Silhouette descends from top to bottom
            beam.silhouetteProgress = math.min(1.0, elapsed / beam.silhouetteTime)

            -- Gradually grow the beam during silhouette phase
            beam.beamGrowth = beam.silhouetteProgress * beam.silhouetteProgress * 0.4

            -- If silhouette has reached bottom, transition to expand phase and trigger shake
            if beam.silhouetteProgress >= 1.0 then
                beam.phase = "expand"

                -- Trigger screen shake when silhouette lands
                if not beam.shakeTriggered then
                    self:startScreenShake(3, 0.2)
                    beam.shakeTriggered = true

                    -- CREATE IMPACT EFFECT AT THE SAME TIME AS SCREEN SHAKE
                    local cell = self:getCell(beam.row, beam.col)
                    if cell then
                        -- Calculate impact position (center of cell, bottom area)
                        local impactX = cell.x + GAME.CONSTANTS.TILE_SIZE / 2
                        local impactY = cell.y + GAME.CONSTANTS.TILE_SIZE - 15

                        -- Determine unit type for appropriate dust effect
                        local unitType = "building" -- Default for beam-spawned units
                        if beam.unitToPlace then
                            -- Check if it's a player unit (mech) or Rock
                            unitType = (beam.unitToPlace.player == 1 or beam.unitToPlace.player == 2) and "mech" or "building"
                        end

                        -- Create the impact effect
                        self:createImpactEffect(impactX, impactY, unitType)
                    end

                    -- Set a timer to place the unit after a short delay
                    beam.unitPlaceTime = elapsed + 0.15 -- 150ms after shake starts
                end
            end
        elseif beam.phase == "expand" then
            -- Continue expanding from silhouette phase with easing
            local expandProgress = (elapsed - beam.silhouetteTime) / beam.expandTime
            local easedProgress = 1 - (1 - math.min(1.0, expandProgress)) * (1 - math.min(1.0, expandProgress))
            beam.width = 0.3 + (0.7 * easedProgress)

            -- Check if it's time to place the unit
            if beam.unitToPlace and beam.unitPlaceTime and elapsed >= beam.unitPlaceTime then
                -- Place the unit directly
                self:placeUnit(beam.unitToPlace, beam.row, beam.col)

                -- Play earthquake sound effect when unit enters
                self:playEarthquakeSound()

                -- Only place once
                beam.unitToPlace = nil
                beam.unitPlaceTime = nil
            end

            if elapsed >= beam.silhouetteTime + beam.expandTime then
                beam.phase = "hold"
            end
        elseif beam.phase == "hold" then
            beam.width = 1.0
            if elapsed >= beam.silhouetteTime + beam.expandTime + beam.holdTime then
                beam.phase = "fade"
            end
        elseif beam.phase == "fade" then
            local fadeProgress = (elapsed - beam.silhouetteTime - beam.expandTime - beam.holdTime) / beam.fadeTime
            beam.alpha = 1.0 - fadeProgress
        end

        -- Remove if duration expired
        if elapsed >= beam.duration then
            table.remove(self.spawnBeams, i)
        end
    end
end

function playGridClass:drawBeamEffects()
    if not self.spawnBeams then return end

    for _, beam in ipairs(self.spawnBeams) do
        local cell = self:getCell(beam.row, beam.col)
        if cell then
            -- Calculate beam dimensions
            local cellSize = GAME.CONSTANTS.TILE_SIZE
            local beamWidth

            if beam.phase == "silhouette" then
                -- Make beam wider than silhouette from the start but still grow
                beamWidth = cellSize * (beam.width + beam.beamGrowth) * 0.95
            else
                beamWidth = cellSize * beam.width * 0.95
            end

            -- Center the beam in the cell
            local x = cell.x + (cellSize - beamWidth) / 2
            local y = cell.y

            -- Position ellipse at the bottom of the beam
            local ellipseY = y + cellSize - 15
            local ellipseHeight = cellSize * 0.15
            local ellipseX = x + beamWidth/2
            local ellipseWidth = beamWidth * 1

            -- Draw beam in all phases, but with varying intensity
            if beam.phase == "silhouette" then
                -- During silhouette phase, draw a translucent beam
                local beamAlpha = 0.4 + beam.silhouetteProgress * 0.3 -- Increase opacity as silhouette descends
                love.graphics.setColor(1, 1, 1, beamAlpha)
                love.graphics.rectangle("fill", 
                    x, 
                    0, 
                    beamWidth, 
                    ellipseY)
                -- Draw the bottom ellipse from the beginning
                -- Create stencil function to only draw bottom half
                local stencilFunc = function()
                    -- Create rectangle covering only bottom half of ellipse area
                    love.graphics.rectangle("fill", 
                        ellipseX - ellipseWidth, 
                        ellipseY, 
                        ellipseWidth*2, 
                        ellipseHeight)
                end

                -- Apply stencil
                love.graphics.stencil(stencilFunc, "replace", 1)
                love.graphics.setStencilTest("greater", 0)

                -- Draw full ellipse (but only bottom half will show)
                love.graphics.setColor(1, 1, 1, beamAlpha * 0.8)
                love.graphics.ellipse("fill", ellipseX, ellipseY, ellipseWidth/2, ellipseHeight/2)

                -- Clear stencil
                love.graphics.setStencilTest()

                -- Draw the ellipse silhouette descending from top with acceleration
                local silhouetteHeight = cellSize * 0.7 -- Elongated
                local silhouetteWidth = cellSize * 0.2  -- Narrow

                -- Calculate silhouette position (starts above screen, ends at bottom of cell)
                local startY = -silhouetteHeight / 2
                local endY = ellipseY - silhouetteHeight / 4

                local easedProgress = beam.silhouetteProgress * beam.silhouetteProgress

                local silhouetteY = startY + (endY - startY) * easedProgress

                -- Add subtle time-based movement to silhouette
                local wobbleX = math.sin(love.timer.getTime() * 3) * 1.5
                local wobbleY = math.cos(love.timer.getTime() * 2) * 1

                -- Draw subtle silhouette halo/aura (lighter and more translucent)
                love.graphics.setColor(0.1, 0.1, 0.15, 0.15)
                love.graphics.ellipse("fill", 
                    ellipseX + wobbleX * 0.5, 
                    silhouetteY + wobbleY * 0.5, 
                    silhouetteWidth/2 * 1.3, 
                    silhouetteHeight/2 * 1.2)

                -- Draw the main silhouette with a much more subtle, translucent appearance
                love.graphics.setColor(0.2, 0.2, 0.25, 0.3) -- Much lighter and more translucent
                love.graphics.ellipse("fill", 
                    ellipseX + wobbleX, 
                    silhouetteY + wobbleY, 
                    silhouetteWidth/2, 
                    silhouetteHeight/2)

                -- Add minimal internal texture
                for i = 1, 6 do
                    local innerRadius = silhouetteWidth * 0.3 * math.random()
                    local angle = math.random() * math.pi * 2
                    local ix = ellipseX + wobbleX + math.cos(angle) * innerRadius
                    local iy = silhouetteY + wobbleY + math.sin(angle) * (innerRadius * silhouetteHeight/silhouetteWidth)

                    -- Very subtle internal highlights
                    love.graphics.setColor(0.25, 0.25, 0.3, 0.15 * math.random())
                    love.graphics.circle("fill", ix, iy, math.random() * 2 + 1)
                end

                -- Add subtle edge noise (fewer particles, more translucent)
                local noiseCount = 15
                local time = love.timer.getTime()

                for i = 1, noiseCount do
                    -- Base angle with time-based drift
                    local baseAngle = (i / noiseCount) * math.pi * 2
                    local angleOffset = math.sin(time * 2 + i * 0.5) * 0.2
                    local angle = baseAngle + angleOffset

                    -- Less pronounced noise
                    local noiseFactor = 0.7 + 0.3 * math.sin(time * 3 + i * 0.7)
                    local noise = (math.random() * 2 + 1) * noiseFactor

                    -- Calculate position with elliptical distortion
                    local rx = math.cos(angle) * (silhouetteWidth/2 + noise)
                    local ry = math.sin(angle) * (silhouetteHeight/2 + noise * 0.5)

                    -- Adjust for silhouette wobble
                    local px = ellipseX + wobbleX + rx
                    local py = silhouetteY + wobbleY + ry

                    -- Smaller particles with lower opacity
                    local size = math.random() * 1.5 + 0.8
                    local opacity = 0.1 + 0.15 * math.random() -- Very low opacity

                    -- Light gray color for particles
                    love.graphics.setColor(0.2, 0.2, 0.25, opacity * math.random())
                    love.graphics.circle("fill", px, py, size)
                end

                -- Add very subtle trailing wisps
                for i = 1, 4 do -- Fewer wisps
                    local wispLength = silhouetteHeight * (0.3 + 0.3 * math.random())
                    local wispWidth = silhouetteWidth * (0.15 + 0.2 * math.random())
                    local wispY = silhouetteY - wispLength * (0.5 + 0.5 * math.random())
                    local wispOffset = (math.random() - 0.5) * silhouetteWidth * 0.6

                    for j = 1, 3 do -- Fewer segments
                        local segment = j / 3
                        local segY = silhouetteY - (wispLength * segment)
                        local waveOffset = math.sin(segment * math.pi + time * 2) * 2 * (1-segment)
                        local segX = ellipseX + wispOffset * (1-segment) + waveOffset
                        local segSize = wispWidth * 0.4 * (1-segment)

                        -- Very translucent wisps
                        love.graphics.setColor(0.2, 0.2, 0.25, 0.1 * (1-segment))
                        love.graphics.ellipse("fill", segX, segY, segSize/2, segSize/2)
                    end
                end

                -- If silhouette is close to landing, start drawing a growing shadow below it
                if easedProgress > 0.7 then
                    local shadowProgress = (easedProgress - 0.7) / 0.3
                    local shadowWidth = cellSize * 0.5 * shadowProgress
                    local shadowHeight = cellSize * 0.06 * shadowProgress

                    -- Add shadow blur effect with multiple layers
                    for i = 1, 3 do
                        local scale = 1 + (i-1) * 0.3
                        local alpha = (0.4 - (i-1) * 0.1) * shadowProgress
                        love.graphics.setColor(0, 0, 0, alpha)
                        love.graphics.ellipse("fill", 
                            ellipseX, 
                            ellipseY, 
                            (shadowWidth/2) * scale, 
                            (shadowHeight/2) * scale)
                    end
                end

            else
                -- For other phases, use the standard beam drawing with easing
                -- Ease-out effect for beam (starts fast, slows down)
                local expandProgress
                if beam.phase == "expand" then
                    local elapsed = love.timer.getTime() - beam.startTime - beam.silhouetteTime
                    local linearProgress = elapsed / beam.expandTime
                    -- Quadratic ease-out: y = 1 - (1-x)²
                    expandProgress = 1 - (1 - math.min(1.0, linearProgress)) * (1 - math.min(1.0, linearProgress))

                    -- Apply the eased expansion to the beam's alpha
                    local combinedAlpha = beam.alpha * (0.7 + expandProgress * 0.3)
                    love.graphics.setColor(1, 1, 1, combinedAlpha)
                else
                    love.graphics.setColor(1, 1, 1, beam.alpha)
                end

                -- Create a subtle pulsing effect during expansion
                local pulseAmount = 0
                if beam.phase == "expand" then
                    pulseAmount = math.sin(love.timer.getTime() * 15) * 3
                end

                love.graphics.rectangle("fill", 
                    x - pulseAmount/2, 
                    0, 
                    beamWidth + pulseAmount, 
                    ellipseY)

                -- Create stencil function to only draw bottom half
                local stencilFunc = function()
                    -- Create rectangle covering only bottom half of ellipse area
                    love.graphics.rectangle("fill", 
                        ellipseX - ellipseWidth, 
                        ellipseY, 
                        ellipseWidth*2, 
                        ellipseHeight)
                end

                -- Apply stencil
                love.graphics.stencil(stencilFunc, "replace", 1)
                love.graphics.setStencilTest("greater", 0)

                -- Draw full ellipse (but only bottom half will show)
                love.graphics.setColor(1, 1, 1, beam.alpha)
                love.graphics.ellipse("fill", ellipseX, ellipseY, ellipseWidth/2, ellipseHeight/2)

                -- Clear stencil
                love.graphics.setStencilTest()

                -- During expansion phase, add energy particles flowing down
                if beam.phase == "expand" then
                    -- Energy particles flowing down the beam
                    for i = 1, 10 do
                        local particleY = -i * 25 + (love.timer.getTime() * 200) % (ellipseY + 100)
                        if particleY < ellipseY then
                            local particleWidth = beamWidth * 0.7
                            local particleX = x + (beamWidth - particleWidth) / 2

                            -- Pulse the particles as they flow
                            local particleAlpha = 0.4 + 0.3 * math.sin(love.timer.getTime() * 10 + i)
                            love.graphics.setColor(1, 1, 1, beam.alpha * particleAlpha * expandProgress)
                            love.graphics.rectangle("fill", particleX, particleY, particleWidth, 2 + math.random() * 3)
                        end
                    end
                end
            end
        end
    end

    -- Reset color
    love.graphics.setColor(1, 1, 1, 1)
end

-- Add to playGridClass.lua
function playGridClass:createRangedAttackEffect(fromRow, fromCol, toRow, toCol, attackType)
    if attackType == "beam" then
        -- Play ranged attack sound
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/SFX_shot9.wav", {
                volume = SETTINGS.AUDIO.SFX_VOLUME
            })
        end
    else
        -- Play ranged attack sound
        if SETTINGS.AUDIO.SFX then
            soundCache.play("assets/audio/SFX_shot8.wav", {
                volume = SETTINGS.AUDIO.SFX_VOLUME
            })
        end
    end

    local effect = acquireRangedAttackEffect(self)
    effect.fromRow = fromRow
    effect.fromCol = fromCol
    effect.toRow = toRow
    effect.toCol = toCol
    effect.attackType = attackType or "default"
    effect.startTime = love.timer.getTime()
    effect.duration = 0.5
    effect.angle = atan2(toRow - fromRow, toCol - fromCol)

    table.insert(self.rangedAttackEffects, effect)

    return effect
end

function playGridClass:drawRangedAttackEffects()
    for i = #self.rangedAttackEffects, 1, -1 do
        local effect = self.rangedAttackEffects[i]
        local elapsed = love.timer.getTime() - effect.startTime
        local progress = elapsed / effect.duration
        local alpha = 1 - progress

        -- Get cell positions
        local fromCell = self:getCell(effect.fromRow, effect.fromCol)
        local toCell = self:getCell(effect.toRow, effect.toCol)

        if fromCell and toCell then
            -- FIXED STARTING POINT - always center of emitter cell
            local x1 = fromCell.x + GAME.CONSTANTS.TILE_SIZE / 2
            local y1 = fromCell.y + GAME.CONSTANTS.TILE_SIZE / 2

            -- BASE TARGET POINT
            local baseX2 = toCell.x + GAME.CONSTANTS.TILE_SIZE / 2
            local baseY2 = toCell.y + GAME.CONSTANTS.TILE_SIZE / 2

            -- Calculate base direction and distance
            local dx = baseX2 - x1
            local dy = baseY2 - y1
            local baseDistance = math.sqrt(dx*dx + dy*dy)
            local directionX = dx / baseDistance
            local directionY = dy / baseDistance

            local padding = GAME.CONSTANTS.TILE_SIZE * 1.5
            local minX = math.min(x1, baseX2)
            local minY = math.min(y1, baseY2)
            local maxX = math.max(x1, baseX2)
            local maxY = math.max(y1, baseY2)
            if not self:isRectVisible(minX - padding, minY - padding, maxX + padding, maxY + padding, padding) then
                goto continueRangedEffect
            end

            -- BEAM LENGTH CALCULATION WITH TWO PHASES
            local actualDistance
            local time = love.timer.getTime()

            if progress < 0.15 then
                -- PHASE 1: Beam QUICKLY grows to HALF target distance (0% to 15% of animation time)
                local growthProgress = progress / 0.15  -- 0 to 1 over first 15% of animation
                actualDistance = (baseDistance * 0.5) * growthProgress  -- Only reach 50% of target distance
            else
                -- PHASE 2: LONGER phase with beam fluctuating with MUCH MORE DRAMATIC variation (15% to 100% of animation time)
                local wave1 = math.sin(time * 6.0) * 0.15        -- Fast waves (±15%) - MUCH LARGER
                local wave2 = math.sin(time * 2.8) * 0.18        -- Medium waves (±18%) - MUCH LARGER
                local wave3 = math.sin(time * 0.9) * 0.12        -- Slow waves (±12%) - MUCH LARGER
                local randomFlicker = (math.random() - 0.5) * 0.08  -- Random flicker (±4%) - MUCH LARGER

                -- Combine variations: base distance with HUGE fluctuation range (-40% to +10% of target)
                local lengthVariation = 1.0 + wave1 + wave2 + wave3 + randomFlicker
                lengthVariation = math.max(0.8, math.min(1.05, lengthVariation))  -- Clamp between 60% and 110% - MASSIVE RANGE!

                actualDistance = baseDistance * lengthVariation
            end

            -- Calculate actual end point
            local x2 = x1 + directionX * actualDistance
            local y2 = y1 + directionY * actualDistance

            if effect.attackType == "beam" then
                -- Calculate beam direction for perpendicular offset
                local perpX = -directionY
                local perpY = directionX

                -- Beam expansion phases
                local maxBeamWidth = GAME.CONSTANTS.TILE_SIZE * 0.8
                local beamWidth
                if progress < 0.3 then
                    beamWidth = (progress / 0.3) * maxBeamWidth
                elseif progress < 0.7 then
                    beamWidth = maxBeamWidth
                else
                    local fadeProgress = (progress - 0.7) / 0.3
                    beamWidth = maxBeamWidth * (1 - fadeProgress)
                end

                -- === OUTER BEAM LAYER ===
                local outerEmitterRadius = beamWidth / 2
                local outerTargetRadius = beamWidth / 2

                -- CREATE STENCIL FOR OUTER BEAM
                local outerStencilFunc = function()
                    -- Beam rectangle
                    love.graphics.polygon("fill", 
                        x1 + perpX * beamWidth/2, y1 + perpY * beamWidth/2,
                        x2 + perpX * beamWidth/2, y2 + perpY * beamWidth/2,
                        x2 - perpX * beamWidth/2, y2 - perpY * beamWidth/2,
                        x1 - perpX * beamWidth/2, y1 - perpY * beamWidth/2)

                    -- Emitter ellipse (at fixed starting point)
                    love.graphics.ellipse("fill", x1, y1, outerEmitterRadius, outerEmitterRadius)

                    -- Target ellipse (at fluctuating end point)
                    love.graphics.ellipse("fill", x2, y2, outerTargetRadius, outerTargetRadius)
                end

                -- Apply outer stencil
                love.graphics.stencil(outerStencilFunc, "replace", 1)
                love.graphics.setStencilTest("equal", 1)

                -- OUTER BEAM COLOR - Classic red
                local outerPulse = 0.7 + 0.3 * math.sin(time * 8)

                -- Intensity based on phase
                local intensity
                if progress < 0.15 then
                    -- QUICK growing phase - intensity increases rapidly
                    intensity = 0.6 + (progress / 0.15) * 0.4
                else
                    -- LONG fluctuating phase - constant high intensity
                    intensity = 1.0
                end

                love.graphics.setColor(0.9, 0.2, 0.2, alpha * outerPulse * intensity * 0.8)

                -- Draw outer beam coverage
                local minX = math.min(x1 - outerEmitterRadius, x2 - outerTargetRadius)
                local maxX = math.max(x1 + outerEmitterRadius, x2 + outerTargetRadius)
                local minY = math.min(y1 - outerEmitterRadius, y2 - outerTargetRadius)
                local maxY = math.max(y1 + outerEmitterRadius, y2 + outerTargetRadius)

                local outerPadding = beamWidth
                love.graphics.rectangle("fill", 
                    minX - outerPadding, minY - outerPadding, 
                    (maxX - minX) + outerPadding * 2, (maxY - minY) + outerPadding * 2)

                -- Reset stencil
                love.graphics.setStencilTest()

                -- === INNER BEAM LAYER ===
                -- MAKE INNER BEAM FLUCTUATE TOO in Phase 2
                local innerBeamWidth
                if progress < 0.15 then
                    -- Phase 1: Inner beam grows normally (50% of outer)
                    innerBeamWidth = beamWidth * 0.5
                else
                    -- Phase 2: Inner beam ALSO fluctuates with same dramatic variations
                    local innerWave1 = math.sin(time * 7.0) * 0.12        -- Slightly different frequency
                    local innerWave2 = math.sin(time * 3.5) * 0.15        -- Different waves for inner
                    local innerWave3 = math.sin(time * 1.3) * 0.10        -- Unique patterns
                    local innerFlicker = (math.random() - 0.5) * 0.06     -- Inner flicker

                    -- Inner beam fluctuates between 30% and 70% of outer beam width
                    local innerVariation = 0.5 + innerWave1 + innerWave2 + innerWave3 + innerFlicker
                    innerVariation = math.max(0.3, math.min(0.7, innerVariation))  -- Clamp between 30% and 70%

                    innerBeamWidth = beamWidth * innerVariation
                end

                local innerEmitterRadius = innerBeamWidth / 2
                local innerTargetRadius = innerBeamWidth / 2

                -- CREATE STENCIL FOR INNER BEAM (same shape, fluctuating size)
                local innerStencilFunc = function()
                    -- Inner beam rectangle
                    love.graphics.polygon("fill", 
                        x1 + perpX * innerBeamWidth/2, y1 + perpY * innerBeamWidth/2,
                        x2 + perpX * innerBeamWidth/2, y2 + perpY * innerBeamWidth/2,
                        x2 - perpX * innerBeamWidth/2, y2 - perpY * innerBeamWidth/2,
                        x1 - perpX * innerBeamWidth/2, y1 - perpY * innerBeamWidth/2)

                    -- Inner emitter ellipse (at fixed starting point)
                    love.graphics.ellipse("fill", x1, y1, innerEmitterRadius, innerEmitterRadius)

                    -- Inner target ellipse (at fluctuating end point)
                    love.graphics.ellipse("fill", x2, y2, innerTargetRadius, innerTargetRadius)
                end

                -- Apply inner stencil
                love.graphics.stencil(innerStencilFunc, "replace", 1)
                love.graphics.setStencilTest("equal", 1)

                -- INNER BEAM COLOR - Bright orange-white core
                local innerPulse = 0.9 + 0.1 * math.sin(time * 12)
                love.graphics.setColor(1.0, 0.8, 0.6, alpha * innerPulse * intensity)

                -- Draw inner beam coverage
                local innerMinX = math.min(x1 - innerEmitterRadius, x2 - innerTargetRadius)
                local innerMaxX = math.max(x1 + innerEmitterRadius, x2 + innerTargetRadius)
                local innerMinY = math.min(y1 - innerEmitterRadius, y2 - innerTargetRadius)
                local innerMaxY = math.max(y1 + innerEmitterRadius, y2 + innerTargetRadius)

                local innerPadding = innerBeamWidth
                love.graphics.rectangle("fill", 
                    innerMinX - innerPadding, innerMinY - innerPadding, 
                    (innerMaxX - innerMinX) + innerPadding * 2, (innerMaxY - innerMinY) + innerPadding * 2)

                -- Reset stencil
                love.graphics.setStencilTest()
            elseif effect.attackType == "projectile" then
                -- Artillery projectile effect with realistic arc trajectory
                
                -- Calculate arc trajectory (parabolic path) - MORE EVIDENT ARC
                local arcHeight = baseDistance * 0.6  -- Increased arc height for more evident trajectory
                
                -- Coordinates are already centered from drawRangedAttackEffects function
                -- x1, y1 and x2, y2 are already tile centers, no need to add offset
                
                -- Parabolic arc calculation using already-centered coordinates
                local arcProgress = 4 * progress * (1 - progress)  -- Parabolic curve (0 at start/end, 1 at middle)
                local projectileX = x1 + (x2 - x1) * progress
                local projectileY = y1 + (y2 - y1) * progress - arcHeight * arcProgress
                
                -- Artillery launch shockwave (first 20% of animation) - WHITE COLORS
                if progress < 0.2 then
                    local shockwaveIntensity = progress / 0.2  -- 0 to 1 over first 20%
                    
                    -- Outer shockwave ring - WHITE
                    love.graphics.setColor(1.0, 1.0, 1.0, alpha * (1 - shockwaveIntensity) * 0.8)
                    love.graphics.setLineWidth(3)
                    love.graphics.circle("line", x1, y1, 20 * shockwaveIntensity)
                    
                    -- Inner shockwave ring - LIGHT GRAY
                    love.graphics.setColor(0.9, 0.9, 0.9, alpha * (1 - shockwaveIntensity) * 0.9)
                    love.graphics.setLineWidth(2)
                    love.graphics.circle("line", x1, y1, 12 * shockwaveIntensity)
                    
                    -- Muzzle flash at Artillery position - BRIGHT WHITE
                    love.graphics.setColor(1.0, 1.0, 1.0, alpha * (1 - shockwaveIntensity))
                    love.graphics.circle("fill", x1, y1, 6 * (1 - shockwaveIntensity))
                end
                
                -- ULTRA-LONG CONTINUOUS trail - CENTERED TO FOLLOW ARC
                local trailSegments = 50  -- Ultra-long trail with 50 segments for maximum drama
                for i = 1, trailSegments do
                    local trailProgress = math.max(0, progress - i * 0.003)  -- Even tighter spacing for ultra-continuous trail
                    if trailProgress > 0 then
                        local trailX = x1 + (x2 - x1) * trailProgress
                        local trailY = y1 + (y2 - y1) * trailProgress - arcHeight * (4 * trailProgress * (1 - trailProgress))
                        
                        -- Trail color: white to gray gradient
                        local grayLevel = 1.0 - (i - 1) / (trailSegments - 1) * 0.5  -- From 1.0 to 0.5 (lighter)
                        local trailAlpha = alpha * (1 - (i - 1) / trailSegments) * 0.95  -- Even higher alpha
                        love.graphics.setColor(grayLevel, grayLevel, grayLevel, trailAlpha)
                        love.graphics.circle("fill", trailX, trailY, 5 - i * 0.12)  -- Larger start, slower decrease
                    end
                end
                
                -- Artillery projectile with BEAM-COLORED INTERIOR
                local projectileSize = 12 + 2 * math.sin(progress * 10)  -- Slightly larger, pulsing size
                local time = love.timer.getTime()
                
                -- Outer glow
                love.graphics.setColor(1.0, 1.0, 1.0, alpha * 0.4)
                love.graphics.circle("fill", projectileX, projectileY, projectileSize * 1.3)
                
                -- Main bright white projectile body
                love.graphics.setColor(1.0, 1.0, 1.0, alpha * 0.95)
                love.graphics.circle("fill", projectileX, projectileY, projectileSize)
                
                -- BEAM-COLORED INTERIOR - like the beam effect
                -- Pulsing beam-like core with white color and varying intensity
                local beamPulse = 0.7 + 0.3 * math.sin(time * 15)  -- Fast pulsing like beam effect
                local beamAlpha = alpha * beamPulse * 0.9
                love.graphics.setColor(1.0, 1.0, 1.0, beamAlpha)
                love.graphics.circle("fill", projectileX, projectileY, projectileSize * 0.6)
                
                -- Inner beam core with even more intensity
                local innerPulse = 0.8 + 0.2 * math.sin(time * 20)  -- Faster inner pulse
                love.graphics.setColor(1.0, 1.0, 1.0, alpha * innerPulse)
                love.graphics.circle("fill", projectileX, projectileY, projectileSize * 0.3)
                
                -- Artillery impact - NO VISIBLE SHOCKWAVE (as requested)
                if progress > 0.75 then  -- Start impact effects at 75%
                    local impactIntensity = (progress - 0.75) / 0.25 -- 0 to 1 over last 25%
                    
                    -- Add subtle screenshake for non-killing hits
                    if impactIntensity > 0.5 and not self.artilleryShakeTriggered then
                        self:startScreenShake(3, 0.3)  -- Much smaller than destruction (8, 0.8)
                        self.artilleryShakeTriggered = true
                    end
                    
                    -- No visible impact shockwave - removed as requested
                else
                    -- Reset screenshake flag when effect is not active
                    self.artilleryShakeTriggered = false
                end
                
                -- Graphics state is managed by the function-level reset
            end
        end

        -- Remove completed effects
        if elapsed >= effect.duration then
            self:recycleRangedAttackEffect(effect)
            table.remove(self.rangedAttackEffects, i)
        end

        ::continueRangedEffect::
    end

    -- Reset graphics state
    love.graphics.setLineWidth(1)
    love.graphics.setColor(1, 1, 1, 1)
end

function playGridClass:enter()
    self:init()
    self.unitImageCache = {}
    self.tileImageCache = {}
    self:preloadUnitImages()
    self:preloadTileImages()
end

function playGridClass:draw()

    -- Draw the grid background
    self:drawGridBackground()

    -- Draw all grid cells
    self:drawGridCells()

    -- Draw player-colored highlighted cells - PNG ONLY
    self:drawHighlightedCells()

    -- Draw PNG action previews
    self:drawActionPreviews()

    self:drawHoverIndicator()

    -- Draw coordinate labels
    self:drawCoordinateLabels()

    -- Draw flashing cells on top
    self:drawFlashingCells()

    self:drawBuildingPlacementEffects()

    self:drawImpactEffects()

    self:drawAIDecisionEffects()

    self:drawUnits()

    self:drawTeslaStrikeEffects()

    self:drawBeamEffects()

    self:drawCommandHubScanEffects()

    self:drawRangedAttackEffects()

    self:drawDestructionEffects()

    self:drawFloatingTexts()
end

function playGridClass:showHoverIndicator(cell)
    -- Don't show indicator if no cell
    if not cell then
        return
    end

    -- Check if this is a different cell than the current hover cell
    local cellChanged = false
    if not self.mouseHoverCell or 
       self.mouseHoverCell.row ~= cell.row or self.mouseHoverCell.col ~= cell.col then
        cellChanged = true
    end

    -- Set the hover cell
    self.mouseHoverCell = cell

    -- Play sound effect when cell changes (works for both mouse and keyboard)
    if cellChanged and SETTINGS.AUDIO.SFX then
        -- Use single grid navigation sound
        soundCache.play("assets/audio/GenericButton14.wav", {
            volume = SETTINGS.AUDIO.SFX_VOLUME,
            clone = false
        })
    end

    -- Don't show visual indicator if UI navigation is active, but still allow sound
    if self.uiNavigationActive then
        return
    end

    -- Always use neutral color for hover indicator by default
    self.hoverIndicatorColor = {203/255, 183/255, 158/255, 0.9} -- Neutral tan
    self.actionIndicatorColor = nil

    -- Check if the hovered cell has an action highlight
    if cell.actionHighlight then
        -- The cell is already getting some kind of highlight from the game logic
        if cell.actionHighlight == "move" then
            -- Movement highlight - improved green
            self.actionIndicatorColor = {68/255, 157/255, 72/255, 0.9} -- Brighter green
        elseif cell.actionHighlight == "attack" then
            -- Attack highlight - improved red
            self.actionIndicatorColor = {200/255, 66/255, 50/255, 0.9} -- Brighter red
        elseif cell.actionHighlight == "repair" then
            -- Repair highlight - improved gold
            self.actionIndicatorColor = {214/255, 164/255, 41/255, 0.9} -- Brighter gold
        elseif cell.actionHighlight == "deploy" then
            -- Deployment highlight - improved blue
            self.actionIndicatorColor = {79/255, 142/255, 183/255, 0.9} -- Brighter blue
        end
    end
end

-- Centralized method to hide the hover indicator
function playGridClass:hideHoverIndicator()
    -- Clear hover cell reference and colors
    self.mouseHoverCell = nil
    self.hoverIndicatorColor = nil
    self.actionIndicatorColor = nil
end

function playGridClass:updateHoverState(x, y)
    -- Check if UI navigation is active first
    if self.uiNavigationActive then
        self:hideHoverIndicator()
        return
    end

    -- Only update hover state when mouse is over the grid
    if self:isPointInGrid(x, y) then
        local row, col = self:screenToGridCoordinates(x, y)
        local cell = self:getCell(row, col)
        if cell then
            self:showHoverIndicator(cell)
        else
            self:hideHoverIndicator()
        end
    else
        -- Mouse is outside grid, hide indicator
        self:hideHoverIndicator()
    end
end

-- Hide the hover indicator completely
function playGridClass:forceHideHoverIndicator()
    -- Set a special flag to force indicator hiding
    self.forceHiddenHoverIndicator = true
    -- Also hide it normally
    self:hideHoverIndicator()
end

-- Restore the hover indicator's normal behavior
function playGridClass:restoreHoverIndicator()
    -- Remove the force hidden flag
    self.forceHiddenHoverIndicator = false

    -- If mouse position is in the grid, restore hover indicator based on current position
    local x, y = love.mouse.getPosition()
    x, y = (x - SETTINGS.DISPLAY.OFFSETX) / SETTINGS.DISPLAY.SCALE, (y - SETTINGS.DISPLAY.OFFSETY) / SETTINGS.DISPLAY.SCALE

    if self:isPointInGrid(x, y) then
        local row, col = self:screenToGridCoordinates(x, y)
        local cell = self:getCell(row, col)
        if cell then
            self:showHoverIndicator(cell)
        end
    end
end

return playGridClass
