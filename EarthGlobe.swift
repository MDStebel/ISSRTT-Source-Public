//
//  EarthGlobe.swift
//  ISS Real-Time Tracker
//
//  Created by Michael Stebel on 8/7/16.
//  Copyright © 2016-2020 Michael Stebel Consulting, LLC. All rights reserved.
//  Portions Copyright © 2017 David Mojdehi
//

import SceneKit
import QuartzCore


let affectedBySpring = 1 << 1
let ambientLightIntensity = CGFloat(90)                         // The default value is 1000
let cameraAltitude = Float(1.85)
let dayNumberOfWinterStolsticeInYear = 356.0                     // The winter solstice is on approximately Dec 21, 22, or 23
let daysInAYear = Globals.numberOfDaysInAYear
let defaultCameraFov = CGFloat(30)
let distanceToISSOrbit = Globals.ISSOrbitAltitudeInScene
let dragWidthInDegrees = 180.0                                   // The amount to rotate the globe on one edge-to-edge swipe (in degrees)
let globeDefaultRotationSpeedInSeconds = 90.0                    // 360° revolution in 90 seconds
let globeRadius = Globals.globeRadiusFactor
let glowPointAltitude = Globals.orbitalAltitudeFactor
let glowPointWidth = CGFloat(0.16)                               // The size factor for the marker
let maxFov = CGFloat(40.0)                                       // Max zoom in degrees
let maxLatLonPerUnity = 1.1
let minFov = CGFloat(10.0)                                       // Min zoom in degrees
let minLatLonPerUnity = -0.1
let sceneBoxSize = CGFloat(1000.0)
let tiltOfEarthAxisInDegrees = Globals.earthTiltInDegrees
let tiltOfEarthAxisInRadians = Globals.earthTiltInRadians


/// The Earth Globe Model
class EarthGlobe {
    
    var camera = SCNCamera()
    var cameraNode = SCNNode()
    var gestureHost : SCNView?
    var globe = SCNNode()
    var lastFovBeforeZoom : CGFloat?
    var lastPanLoc : CGPoint?
    var orbitTrack = SCNTorus()
    var scene = SCNScene()
    var seasonalTilt = SCNNode()
    var skybox = SCNNode()
    var sun = SCNNode()
    var userRotation = SCNNode()
    var userTilt = SCNNode()
    
    
    internal init() {
        
        // Create the globe
        let globeShape = SCNSphere(radius: CGFloat(globeRadius) )
        globeShape.segmentCount = 192
        
        // Use the high-resolution image
        guard let earthMaterial = globeShape.firstMaterial else { return }

        // Texture revealed by diffuse light sources
        earthMaterial.diffuse.contents = "8081_earthmap_8190px.jpg"
        
        let emission = SCNMaterialProperty()
        emission.contents = "8081_earthlights_8190px"
        earthMaterial.setValue(emission, forKey: "emissionTexture")
        
        /// OpenGL lighting map
        let shaderModifier =    """
                                uniform sampler2D emissionTexture;
                                vec3 light = _lightingContribution.diffuse;
                                float lum = max(0.0, 1 - (0.2126 * light.r + 0.7152 * light.g + 0.0722 * light.b));
                                vec4 emission = texture2D(emissionTexture, _surface.diffuseTexcoord) * lum * 1.0;
                                _output.color += emission;
                                """
        earthMaterial.shaderModifiers = [.fragment: shaderModifier]
        
        // Texture revealed by specular light sources
        //earthMaterial.specular.contents = "earth_lights.jpg"
        earthMaterial.specular.contents = "8081_earthspec_512px.jpg"
        earthMaterial.specular.intensity = 0.2
        
        // Oceans are reflective and land is matte
        earthMaterial.metalness.contents = "metalness-1.png"
        earthMaterial.roughness.contents = "roughness-1.png"

        // Make the mountains appear taller
        // (gives them shadows from point lights, but doesn't make them stick up beyond the edges)
        earthMaterial.normal.contents = "earth-bump-1.png"
        earthMaterial.normal.intensity = 0.4
        
        //earthMaterial.reflective.contents = "envmap.jpg"
        //earthMaterial.reflective.intensity = 0.75
        earthMaterial.fresnelExponent = 2
        globe.geometry = globeShape
        
        // Globe spins once per minute
        let spinRotation = SCNAction.rotate(by: 2 * .pi, around: SCNVector3(0, 1, 0), duration: globeDefaultRotationSpeedInSeconds)
        let spinAction = SCNAction.repeatForever(spinRotation)
        globe.runAction(spinAction)
        

        // Set up the basic globe nodes
        scene.rootNode.addChildNode(userTilt)
        userTilt.addChildNode(userRotation)
        userRotation.addChildNode(globe)
        
    }
    
    
    /// Set up our scene
    /// - Parameters:
    ///   - theScene: The scene view to use
    ///   - forARKit: True if this is used with ARKit
    internal func setupInSceneView(_ theScene: SCNView, forARKit : Bool ) {
        
        theScene.scene = self.scene
        theScene.autoenablesDefaultLighting = false
        theScene.showsStatistics = false
        
        self.gestureHost = theScene
        
        if forARKit {
            
            theScene.allowsCameraControl = true
            skybox.removeFromParentNode()
            
        } else {
            
            finishNonARSetup()
            
            theScene.allowsCameraControl = false
            
            let pan = UIPanGestureRecognizer(target: self, action:#selector(EarthGlobe.onPanGesture(pan:)))
            theScene.addGestureRecognizer(pan)
//            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(EarthGlobe.onPinchGesture(pinch:)))
//            theScene.addGestureRecognizer(pinch)
            
        }
        
    }
    
    
    private func finishNonARSetup() {

        // Provides ambient light to light the globe a bit in nighttime.
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = ambientLightIntensity // default is 1000!
        
        // Create and add a camera to the scene
        // Set up a 'telephoto' shot (to avoid any fisheye effects)
        // Telephoto: narrow field of view at a long distance
        camera.fieldOfView = defaultCameraFov
        camera.zFar = 1000
        cameraNode.position = SCNVector3(x: 0, y: 0, z:  globeRadius + cameraAltitude )
        cameraNode.constraints = [ SCNLookAtConstraint(target: self.globe) ]
        cameraNode.light = ambientLight
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        
    }

    
    @objc fileprivate func onPanGesture(pan : UIPanGestureRecognizer) {
        
        // Handle panning and rotating
        guard let sceneView = pan.view else { return }
        let loc = pan.location(in: sceneView)
        
        if pan.state == .began {
            handlePanBegan(loc)
        } else {
            guard pan.numberOfTouches == 1 else { return }
            self.handlePanCommon(loc, viewSize: sceneView.frame.size)
        }
        
    }
    
    
    @objc fileprivate func onPinchGesture(pinch: UIPinchGestureRecognizer) {
        
        // Update the FOV of the camera
        if pinch.state == .began {
            self.lastFovBeforeZoom = self.camera.fieldOfView
        } else {
            if let lastFov = self.lastFovBeforeZoom {
                var newFov = lastFov / CGFloat(pinch.scale)
                if newFov < minFov {
                    newFov = minFov
                } else if newFov > maxFov {
                    newFov = maxFov
                }
                self.camera.fieldOfView =  newFov
            }
        }
        
    }
    
    
    public func handlePanBegan(_ loc: CGPoint) {
        
        lastPanLoc = loc
        
    }
    
    
    public func handlePanCommon(_ loc: CGPoint, viewSize: CGSize) {
        guard let lastPanLoc = lastPanLoc else { return }
        
        // Measure the movement change
        let delta = CGSize(width: (lastPanLoc.x - loc.x) / viewSize.width, height: (lastPanLoc.y - loc.y) / viewSize.height)
        
        //  DeltaX = amount of rotation to apply (about the world axis)
        //  DeltaY = amount of tilt to apply (to the axis itself)
        if delta.width != 0.0 || delta.height != 0.0 {
            
            // As the user zooms in (smaller fieldOfView value), the finger travel is reduced
            let fovProportion = (self.camera.fieldOfView - minFov) / (maxFov - minFov)
            let fovProportionRadians = Float(fovProportion * CGFloat(dragWidthInDegrees) ) * (.pi / 180)
            let rotationAboutAxis = Float(delta.width) * fovProportionRadians
            let tiltOfAxisItself = Float(delta.height) * fovProportionRadians
            
            // First, apply the rotation
            let rotate = SCNMatrix4RotateF(userRotation.worldTransform, -rotationAboutAxis, 0.0, 1.0, 0.0)
            userRotation.setWorldTransform(rotate)
            
            // Now, apply the tilt
            let tilt = SCNMatrix4RotateF(userTilt.worldTransform, -tiltOfAxisItself, 1.0, 0.0, 0.0)
            userTilt.setWorldTransform(tilt)
            
        }
        
        self.lastPanLoc = loc
        
    }
    
}


func SCNMatrix4RotateF(_ src: SCNMatrix4, _ angle : Float, _ x : Float, _ y : Float, _ z : Float) -> SCNMatrix4 {
    
    return SCNMatrix4Rotate(src, angle, x, y, z)
    
}