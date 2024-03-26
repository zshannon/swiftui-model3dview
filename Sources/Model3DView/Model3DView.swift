/*
 * Model3DView.swift
 * Created by Freek (github.com/frzi) on 08-08-2021.
 */

import Combine
import DeveloperToolsSupport
import GLTFSceneKit
import SceneKit
import SwiftUI

// MARK: - Model3DView
/// View to render a 3D model or scene.
///
/// This view utilizes SceneKit to render a 3D model or a SceneKit scene.
/// ```swift
/// Model3DView(named: "duck.gltf")
/// 	.transform(scale: 0.5)
/// 	.camera(PerspectiveCamera())
/// ```
///
/// - Note: It is advised to keep the number of `Model3DView`s simultaneously on screen to a minimum.
public struct Model3DView: ViewRepresentable {

	private let sceneFile: SceneFileType

	private var onLoadHandlers: [(ModelLoadState) -> Void] = []
	private var showsStatistics = false

	// MARK: - Initializers
	/// Load a 3D asset from the app's bundle.
	public init(named: String) {
		sceneFile = .url(Bundle.main.url(forResource: named, withExtension: nil))
	}
	
	/// Load a 3D asset from a file URL.
	public init(file: URL) {
		#if DEBUG
		precondition(file.isFileURL, "Given URL is not a file URL.")
		#endif
		sceneFile = .url(file)
	}
	
	/// Load 3D assets from a SceneKit scene instance.
	///
	/// When passing a SceneKit scene instance to `Model3DView` all its contents will be copied to an internal scene.
	/// Although geometry data will be shared (an optimization provided by SceneKit), any changes to nodes in the
	/// original scene will not apply to the scene rendered by `Model3DView`.
	///
	/// - Important: It is important pass an already initialized instance of `SCNScene`.
	/// ```swift
	/// // ❌ Bad
	/// var body: some View {
	/// 	Model3DView(scene: SCNScene(named: "myscene")!)
	/// }
	///
	/// // ✅ Good
	/// static var scene = SCNScene(named: "myscene")!
	///
	/// var body: some View {
	/// 	Model3DView(scene: Self.scene)
	/// }
	/// ```
	/// - Warning: This feature may be removed in a future version of `Model3DView`.
	public init(scene: SCNScene) {
		sceneFile = .reference(scene)
	}

	// MARK: - Private implementations
	private func makeView(context: Context) -> SCNView {
		let view = SCNView()
//		view.autoenablesDefaultLighting = true
		view.backgroundColor = .clear

		// Framerate
		#if os(macOS)
		if #available(macOS 12, *) {
			view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? view.preferredFramesPerSecond
		}
		#else
		view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
		#endif

		// Anti-aliasing.
		// If the screen's pixel ratio is above 2 we disable anti-aliasing. Otherwise use MSAAx2.
		// This may become a view modifier at some point instead.
		#if os(macOS)
		let screenScale = NSScreen.main?.backingScaleFactor ?? 1
		#elseif os(iOS) || os(tvOS)
		let screenScale = UIScreen.main.scale
		#endif

		view.antialiasingMode = screenScale > 2 ? .none : .multisampling2X

		context.coordinator.camera = context.environment.camera
		context.coordinator.setView(view)

		return view
	}

	private func updateView(_ view: SCNView, context: Context) {
		view.showsStatistics = showsStatistics

		// Update the coordinator.
		let coordinator = context.coordinator
		coordinator.setSceneFile(sceneFile)

		// Properties.
		coordinator.camera = context.environment.camera
		coordinator.onLoadHandlers = onLoadHandlers

		// Methods.
		coordinator.setIBL(settings: context.environment.ibl)
		coordinator.setSkybox(asset: context.environment.skybox)
		coordinator.setTransform(
			rotate: context.environment.transform3D.rotation,
			scale: context.environment.transform3D.scale,
			translate: context.environment.transform3D.translation)
	}
}

// MARK: - Equatable
extension Model3DView: Equatable {
	public static func == (lhs: Model3DView, rhs: Model3DView) -> Bool {
		lhs.sceneFile == rhs.sceneFile
	}
}

// MARK: - ViewRepresentable implementations
extension Model3DView {
	public func makeCoordinator() -> SceneCoordinator {
		SceneCoordinator()
	}
	
	#if os(macOS)
	public func makeNSView(context: Context) -> SCNView {
		makeView(context: context)
	}
	
	public func updateNSView(_ view: SCNView, context: Context) {
		updateView(view, context: context)
	}
	#elseif os(iOS) || os(tvOS)
	public func makeUIView(context: Context) -> SCNView {
		makeView(context: context)
	}
	
	public func updateUIView(_ view: SCNView, context: Context) {
		updateView(view, context: context)
	}
	#endif
}

// MARK: - Coordinator
extension Model3DView {
	/// Holds all the state values.
	public class SceneCoordinator: NSObject {

		private enum LoadError: Error {
			case unableToLoad
		}

		// Keeping track of already loaded resources.
		private static let imageCache = ResourcesCache<URL, PlatformImage>()
		private static let sceneCache = AsyncResourcesCache<URL, SCNScene>()

		// MARK: -
		private weak var view: SCNView!

		private let cameraNode = SCNNode()
		private let contentNode = SCNNode()
		private let scene = SCNScene()

		private var loadSceneCancellable: (any Cancellable)?
		private var loadedScene: SCNScene? // Keep a reference for `AsyncResourcesCache`.

		fileprivate var onLoadHandlers: [(ModelLoadState) -> Void] = []

		// Properties for diffing.
		private var sceneFile: SceneFileType?
		private var ibl: IBLValues?
		private var skybox: URL?

		// Instead of using the `.simdPosition` and `.simdOrientation` properties, use a transform matrix instead.
		// We want to depend on as little SceneKit features as possible.
		private var transform = Matrix4x4.identity

		private var contentScale: Float = 1
		private var contentCenter: Vector3 = 0
		fileprivate var camera: Camera! {
			didSet {
				cameraNode.camera?.name = String(describing: type(of: camera))
			}
		}

		// MARK: -
		fileprivate override init() {
			// Prepare the scene to house the loaded models/content.
			cameraNode.camera = SCNCamera()
			cameraNode.name = "Camera"
			scene.rootNode.addChildNode(cameraNode)

			contentNode.name = "Content"
			scene.rootNode.addChildNode(contentNode)
            
            let lightNode: SCNNode = .init()
            lightNode.light = .init()
            lightNode.light!.intensity = 3000
            lightNode.light!.type = .ambient
            scene.rootNode.addChildNode(lightNode)

			super.init()
		}

		// MARK: - Setting scene properties.
		fileprivate func setView(_ sceneView: SCNView) {
			view = sceneView
			view.delegate = self
			view.pointOfView = cameraNode
			view.scene = scene
		}

		fileprivate func setSceneFile(_ sceneFile: SceneFileType) {
			guard self.sceneFile != sceneFile else {
				return
			}

			self.sceneFile = sceneFile

			// Load the scene file/reference.
			// If an url is given, the scene will be loaded asynchronously via `AsyncResourcesCache`, making sure
			// only one instance lives in memory and doesn't block the main thread.
			// TODO: Add (better?) error handling...
			if case .url(let sceneUrl) = sceneFile,
			   let url = sceneUrl
			{
				loadSceneCancellable = Self.sceneCache.resource(for: url) { url, promise in
					do {
						if ["gltf", "glb"].contains(url.pathExtension.lowercased()) {
							let source = GLTFSceneSource(url: url, options: nil)
							let scene = try source.scene()
							promise(.success(scene))
						}
						else {
							let scene = try SCNScene(url: url)
							promise(.success(scene))
						}
					}
					catch {
						print(error)
						promise(.failure(LoadError.unableToLoad))
					}
				}
				.sink { completion in
					if case .failure(_) = completion {
						Task { @MainActor in
							for onLoad in self.onLoadHandlers {
								onLoad(.failure)
							}
						}
					}
				} receiveValue: { [weak self] scene in
					self?.loadedScene = scene
					self?.prepareScene()
				}
			}
			else if case .reference(let scene) = sceneFile {
				loadSceneCancellable = Just(scene)
					.receive(on: RunLoop.main)
					.sink { [weak self] scene in
						self?.loadedScene = scene
						self?.prepareScene()
					}
			}
		}

		private func prepareScene() {
			contentNode.childNodes.forEach { $0.removeFromParentNode() }

			// Copy the root node(s) of the scene, copy their geometry and place them in the coordinator's scene.
			guard let loadedScene else {
				return
			}

			let copiedRoot = loadedScene.rootNode.clone()

			// Copy the materials.
			copiedRoot
				.childNodes { node, _ in node.geometry?.firstMaterial != nil }
				.forEach { node in
					node.geometry = node.geometry?.copy() as? SCNGeometry
				}

			// Scale the scene/model to normalized (-1, 1) scale.
			var maxDimension = max(
				copiedRoot.boundingBox.max.x - copiedRoot.boundingBox.min.x,
				copiedRoot.boundingBox.max.y - copiedRoot.boundingBox.min.y,
				copiedRoot.boundingBox.max.z - copiedRoot.boundingBox.min.z)
			maxDimension = maxDimension == 0 ? 1 : maxDimension
			maxDimension *= 1.1 // Making sure there's a bit of padding.
			
			contentScale = Float(2 / maxDimension)

			contentCenter = mix(Vector3(copiedRoot.boundingBox.min), Vector3(copiedRoot.boundingBox.max), t: Float(0.5))
			contentCenter *= contentScale

			contentNode.addChildNode(copiedRoot)

			Task { @MainActor in
				for onLoad in self.onLoadHandlers {
					onLoad(.success(copiedRoot))
				}
			}
		}

		// MARK: - Apply new values.
		/// Apply scene transforms.
		fileprivate func setTransform(rotate: Euler, scale: Vector3, translate: Vector3) {
			transform = Matrix4x4(scale: scale) * Matrix4x4(translation: translate) * Matrix4x4(Quaternion(rotate))
		}

		/// Set the skybox texture from file.
		fileprivate func setSkybox(asset: URL?) {
			guard asset != skybox else {
				return
			}

			if let asset = asset {
				scene.background.contents = Self.imageCache.resource(for: asset) { url in
					PlatformImage(contentsOfFile: url.path)
				}
			}
			else {
				scene.background.contents = nil
			}

			skybox = asset
		}
		
		/// Set the image based lighting (IBL) texture and intensity.
		fileprivate func setIBL(settings: IBLValues?) {
			guard ibl?.url != settings?.url || ibl?.intensity != settings?.intensity else {
				return
			}
			
			if let settings = settings,
				let image = Self.imageCache.resource(for: settings.url, action: { url in
					PlatformImage(contentsOfFile: url.path)
				})
			{
				scene.lightingEnvironment.contents = image
				scene.lightingEnvironment.intensity = settings.intensity
			}
			else {
				scene.lightingEnvironment.contents = nil
				scene.lightingEnvironment.intensity = 1
			}
			
			ibl = settings
		}
	}
}

// MARK: - SCNSceneRendererDelegate
/**
 * Note: Methods can - and most likely will - be called on a different thread.
 */
extension Model3DView.SceneCoordinator: SCNSceneRendererDelegate {
	public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
		// Update the content node.
		contentNode.simdTransform = Matrix4x4(scale: Vector3(repeating: contentScale)) * transform
		
		// Update the camera.
		let projection = camera.projectionMatrix(viewport: view.currentViewport.size)
		cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
		
		let rotation = Matrix4x4(Quaternion(camera.rotation))
		let translation = Matrix4x4(translation: camera.position + contentCenter)
		let cameraTransform = translation * rotation
		cameraNode.simdTransform = cameraTransform
	}
}

// MARK: - Modifiers for Model3DView
/**
 * These view modifiers are exclusive to `Model3DView`, modifying their values directly and returning a new copy
 * of said `Model3DView`.
 */
extension Model3DView {
	/// Adds an action to perform when the model is loaded.
	///
	/// Because assets are loaded asynchronously you can use `onLoad` handlers to react to state changes. Use this to
	/// temporarily show a progress bar or a thumbnail, or to display alternative views if loading has failed.
	public func onLoad(perform: @escaping (ModelLoadState) -> Void) -> Self {
		var view = self
		view.onLoadHandlers.append(perform)
		return view
	}
	
	/// Show SceneKit statistics and inspector in the view.
	///
	/// Only use this modifier during development (i.e. using `#if DEBUG`).
	/// ```swift
	/// Model3DView(named: "robot.gltf")
	/// 	#if DEBUG
	/// 	.showStatistics()
	/// 	#endif
	/// ```
	public func showStatistics() -> Self {
		var view = self
		view.showsStatistics = true
		return view
	}
}

// MARK: - Developer Tools
struct Model3DView_Library: LibraryContentProvider {
	@LibraryContentBuilder
	var views: [LibraryItem] {
		LibraryItem(Model3DView(named: "model.gltf"), visible: true, title: "Model3D View")
	}
}
