package io.carius.lars.ar_flutter_plugin

import android.content.Context
import com.google.ar.sceneform.Node
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.math.Quaternion
import com.google.ar.sceneform.assets.RenderableSource

import java.util.concurrent.CompletableFuture
import android.net.Uri
import com.google.ar.sceneform.rendering.*
import com.google.ar.sceneform.ux.*

import io.carius.lars.ar_flutter_plugin.Serialization.*

import io.flutter.plugin.common.MethodChannel


// Responsible for creating Renderables and Nodes
class ArModelBuilder {

    // One shared yellow cube — never allocate Material/Shape per feature point per frame.
    @Volatile
    private var sharedFeaturePointRenderable: ModelRenderable? = null
    private var featurePointRenderableLoading = false

    fun ensureFeaturePointRenderable(context: Context) {
        if (sharedFeaturePointRenderable != null || featurePointRenderableLoading) return
        featurePointRenderableLoading = true
        MaterialFactory.makeOpaqueWithColor(context, Color(android.graphics.Color.YELLOW))
            .thenAccept { material ->
                val cube = ShapeFactory.makeCube(
                    Vector3(0.012f, 0.012f, 0.012f),
                    Vector3.zero(),
                    material
                )
                cube.isShadowCaster = false
                cube.isShadowReceiver = false
                // Critical: feature dots must NOT steal Sceneform ray hits / floor taps.
                cube.collisionShape = null
                sharedFeaturePointRenderable = cube
                featurePointRenderableLoading = false
            }
            .exceptionally {
                featurePointRenderableLoading = false
                null
            }
    }

    /** Places a feature point using the shared renderable at a world position. */
    fun makeFeaturePointNode(context: Context, xPos: Float, yPos: Float, zPos: Float): Node {
        ensureFeaturePointRenderable(context)
        val featurePoint = Node()
        featurePoint.worldPosition = Vector3(xPos, yPos, zPos)
        featurePoint.renderable = sharedFeaturePointRenderable
        // Even before renderable is ready, keep the node non-hittable when it arrives.
        sharedFeaturePointRenderable?.collisionShape = null
        return featurePoint
    }

    fun attachSharedRenderableIfReady(node: Node) {
        val renderable = sharedFeaturePointRenderable ?: return
        if (node.renderable !== renderable) {
            node.renderable = renderable
        }
    }

    // Creates a coordinate system model at the world origin (X-axis: red, Y-axis: green, Z-axis:blue)
    // The code for this function is adapted from Alexander's stackoverflow answer (https://stackoverflow.com/questions/48908358/arcore-how-to-display-world-origin-or-axes-in-debug-mode) 
    fun makeWorldOriginNode(context: Context): Node {
        val axisSize = 0.1f
        val axisRadius = 0.005f

        val rootNode = Node()
        val xNode = Node()
        val yNode = Node()
        val zNode = Node()

        rootNode.addChild(xNode)
        rootNode.addChild(yNode)
        rootNode.addChild(zNode)

        xNode.worldPosition = Vector3(axisSize / 2, 0f, 0f)
        xNode.worldRotation = Quaternion.axisAngle(Vector3(0f, 0f, 1f), 90f)

        yNode.worldPosition = Vector3(0f, axisSize / 2, 0f)

        zNode.worldPosition = Vector3(0f, 0f, axisSize / 2)
        zNode.worldRotation = Quaternion.axisAngle(Vector3(1f, 0f, 0f), 90f)

        MaterialFactory.makeOpaqueWithColor(context, Color(255f, 0f, 0f))
                .thenAccept { redMat ->
                    xNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), redMat)
                }

        MaterialFactory.makeOpaqueWithColor(context, Color(0f, 255f, 0f))
                .thenAccept { greenMat ->
                    yNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), greenMat)
                }

        MaterialFactory.makeOpaqueWithColor(context, Color(0f, 0f, 255f))
                .thenAccept { blueMat ->
                    zNode.renderable = ShapeFactory.makeCylinder(axisRadius, axisSize, Vector3.zero(), blueMat)
                }

        return rootNode
    }

    // Creates a node form a given gltf model path or URL. The gltf asset loading in Scenform is asynchronous, so the function returns a completable future of type Node
    fun makeNodeFromGltf(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)

        ModelRenderable.builder()
                .setSource(context, RenderableSource.builder().setSource(
                        context,
                        Uri.parse(modelPath),
                        RenderableSource.SourceType.GLTF2)
                        .build())
                .setRegistryId(modelPath)
                .build()
                .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally { throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null // return null because java expects void return (in java, void has one instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                }

    return completableFutureNode
    }

    // Creates a node form a given glb model path or URL. The gltf asset loading in Sceneform is asynchronous, so the function returns a compleatable future of type Node
    fun makeNodeFromGlb(context: Context, transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean, name: String, modelPath: String, transformation: ArrayList<Double>): CompletableFuture<CustomTransformableNode> {
        val completableFutureNode: CompletableFuture<CustomTransformableNode> = CompletableFuture()

        val gltfNode = CustomTransformableNode(transformationSystem, objectManagerChannel, enablePans, enableRotation)

        ModelRenderable.builder()
                .setSource(context, RenderableSource.builder().setSource(
                        context,
                        Uri.parse(modelPath),
                        RenderableSource.SourceType.GLB)
                        .build())
                .setRegistryId(modelPath)
                .build()
                .thenAccept{ renderable ->
                    gltfNode.renderable = renderable
                    gltfNode.name = name
                    val transform = deserializeMatrix4(transformation)
                    gltfNode.worldScale = transform.first
                    gltfNode.worldPosition = transform.second
                    gltfNode.worldRotation = transform.third
                    completableFutureNode.complete(gltfNode)
                }
                .exceptionally{throwable ->
                    completableFutureNode.completeExceptionally(throwable)
                    null
                }

        return completableFutureNode
    }
}

class CustomTransformableNode(transformationSystem: TransformationSystem, objectManagerChannel: MethodChannel, enablePans: Boolean, enableRotation: Boolean) :
    TransformableNode(transformationSystem) {

    private lateinit var customTranslationController: CustomTranslationController

    private lateinit var customRotationController: CustomRotationController

    init {
        // Remove standard controllers
        translationController.isEnabled = false
        rotationController.isEnabled = false
        scaleController.isEnabled = false
        removeTransformationController(translationController)
        removeTransformationController(rotationController)
        removeTransformationController(scaleController)


        // Add custom controllers if needed
        if (enablePans) {
            customTranslationController = CustomTranslationController(
                this,
                transformationSystem.dragRecognizer,
                objectManagerChannel
            )
            addTransformationController(customTranslationController)
        }
        if (enableRotation) {
            customRotationController = CustomRotationController(
                this,
                transformationSystem.twistRecognizer,
                objectManagerChannel
            )
            addTransformationController(customRotationController)
        }
    }
}

class CustomTranslationController(transformableNode: BaseTransformableNode, gestureRecognizer: DragGestureRecognizer, objectManagerChannel: MethodChannel) :
    TranslationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: DragGesture): Boolean {
        platformChannel.invokeMethod("onPanStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: DragGesture) {
        platformChannel.invokeMethod("onPanChange", transformableNode.name)
        super.onContinueTransformation(gesture)
        }

    override fun onEndTransformation(gesture: DragGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onPanEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}

class CustomRotationController(transformableNode: BaseTransformableNode, gestureRecognizer: TwistGestureRecognizer, objectManagerChannel: MethodChannel) :
    RotationController(transformableNode, gestureRecognizer) {

    val platformChannel: MethodChannel = objectManagerChannel

    override fun canStartTransformation(gesture: TwistGesture): Boolean {
        platformChannel.invokeMethod("onRotationStart", transformableNode.name)
        super.canStartTransformation(gesture)
        return transformableNode.isSelected
    }

    override fun onContinueTransformation(gesture: TwistGesture) {
        platformChannel.invokeMethod("onRotationChange", transformableNode.name)
        super.onContinueTransformation(gesture)
    }

    override fun onEndTransformation(gesture: TwistGesture) {
        val serializedLocalTransformation = serializeLocalTransformation(transformableNode)
        platformChannel.invokeMethod("onRotationEnd", serializedLocalTransformation)
        super.onEndTransformation(gesture)
     }
}
