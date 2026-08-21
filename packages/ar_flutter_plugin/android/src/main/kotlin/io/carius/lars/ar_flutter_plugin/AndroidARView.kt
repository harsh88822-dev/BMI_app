package io.carius.lars.ar_flutter_plugin

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.widget.Toast
import com.google.ar.core.*
import com.google.ar.core.exceptions.*
import com.google.ar.sceneform.*
import com.google.ar.sceneform.math.Vector3
import com.google.ar.sceneform.ux.*
import io.carius.lars.ar_flutter_plugin.Serialization.deserializeMatrix4
import io.carius.lars.ar_flutter_plugin.Serialization.serializeAnchor
import io.carius.lars.ar_flutter_plugin.Serialization.serializeHitResult
import io.carius.lars.ar_flutter_plugin.Serialization.serializePose
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.CompletableFuture

import android.R
import com.google.ar.sceneform.rendering.*

import android.view.ViewGroup

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import com.google.ar.core.TrackingState














internal class AndroidARView(
        val activity: Activity,
        context: Context,
        messenger: BinaryMessenger,
        id: Int,
        creationParams: Map<String?, Any?>?
) : PlatformView {
    // constants
    private val TAG: String = AndroidARView::class.java.name
    // Lifecycle variables
    private var mUserRequestedInstall = true
    lateinit var activityLifecycleCallbacks: Application.ActivityLifecycleCallbacks
    private val viewContext: Context
    // Platform channels
    private val sessionManagerChannel: MethodChannel = MethodChannel(messenger, "arsession_$id")
    private val objectManagerChannel: MethodChannel = MethodChannel(messenger, "arobjects_$id")
    private val anchorManagerChannel: MethodChannel = MethodChannel(messenger, "aranchors_$id")
    // UI variables
    private lateinit var arSceneView: ArSceneView
    private lateinit var transformationSystem: TransformationSystem
    private var showFeaturePoints = false
    /** Remembers user intent so snapshot can temporarily pause dots then restore. */
    private var wantShowFeaturePoints = false
    private var showAnimatedGuide = false
    private lateinit var animatedGuide: View
    private var pointCloudNode = Node()
    private var worldOriginNode = Node()
    // Setting defaults
    private var enableRotation = false
    private var enablePans = false
    private var keepNodeSelected = true;
    private var footprintSelectionVisualizer = FootprintSelectionVisualizer()
    // Model builder
    private var modelBuilder = ArModelBuilder()
    // Cloud anchor handler
    private lateinit var cloudAnchorHandler: CloudAnchorHandler
    // Reused feature-point nodes — allocating Material/Shape every frame kills ARCore tracking.
    private val featurePointPool = ArrayList<Node>(64)
    private var featurePointFrameCounter = 0
    private val maxFeaturePoints = 48
    private val featurePointUpdateStride = 3 // refresh dots every N frames
    private var pendingPlaneFindingMode: Config.PlaneFindingMode =
        Config.PlaneFindingMode.HORIZONTAL

    private lateinit var sceneUpdateListener: com.google.ar.sceneform.Scene.OnUpdateListener
    private lateinit var onNodeTapListener: com.google.ar.sceneform.Scene.OnPeekTouchListener

    // Method channel handlers
    private val onSessionMethodCall =
            object : MethodChannel.MethodCallHandler {
                override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                    Log.d(TAG, "AndroidARView onsessionmethodcall reveived a call!")
                    when (call.method) {
                        "init" -> {
                            initializeARView(call, result)
                        }
                        "getAnchorPose" -> {
                            val anchorNode = arSceneView.scene.findByName(call.argument("anchorId")) as AnchorNode?
                            val pose = anchorNode?.anchor?.pose
                            if (pose != null) {
                                result.success(serializePose(pose))
                            } else {
                                result.error("Error", "could not get anchor pose", null)
                            }
                        }
                        "getCameraPose" -> {
                            val cameraPose = arSceneView.arFrame?.camera?.displayOrientedPose
                            if (cameraPose != null) {
                                result.success(serializePose(cameraPose))
                            } else {
                                result.error("Error", "could not get camera pose", null)
                            }
                        }
                        "hitTestScreen" -> {
                            try {
                                val x = (call.argument<Number>("x") ?: (arSceneView.width / 2f)).toFloat()
                                val y = (call.argument<Number>("y") ?: (arSceneView.height * 0.72f)).toFloat()
                                val approx = (call.argument<Number>("approxDistanceMeters") ?: 1.4).toFloat()
                                val allowIp = call.argument<Boolean>("allowInstantPlacement") ?: false
                                val hits = performFloorHitTest(x, y, approx, allowIp)
                                result.success(hits)
                            } catch (e: Exception) {
                                Log.e(TAG, "hitTestScreen failed", e)
                                result.success(ArrayList<HashMap<String, Any>>())
                            }
                        }
                        "hitTestFloor" -> {
                            try {
                                result.success(hitTestFloorSamples())
                            } catch (e: Exception) {
                                Log.e(TAG, "hitTestFloor failed", e)
                                result.success(ArrayList<HashMap<String, Any>>())
                            }
                        }
                        "captureCameraJpeg" -> {
                            try {
                                val jpeg = captureCameraJpeg()
                                if (jpeg != null) {
                                    result.success(jpeg)
                                } else {
                                    result.error("e", "AR camera image unavailable", null)
                                }
                            } catch (e: Exception) {
                                Log.e(TAG, "captureCameraJpeg failed", e)
                                result.error("e", e.message, null)
                            }
                        }
                        "snapshot" -> {
                            // Safer screenshot for mid-range Android:
                            // - pause feature-point churn during copy
                            // - guard zero-size view
                            // - full PixelCopy then downscale (dest must match view size)
                            // - JPEG instead of huge PNG
                            // - never double-reply / uncaught exceptions / OOM kill
                            try {
                                // Pause dots only for the copy — restore afterward.
                                showFeaturePoints = false
                                try {
                                    clearFeaturePointChildren()
                                } catch (_: Exception) {
                                }

                                val viewWidth = arSceneView.width
                                val viewHeight = arSceneView.height
                                if (viewWidth <= 0 || viewHeight <= 0) {
                                    showFeaturePoints = wantShowFeaturePoints
                                    result.error("e", "AR view not ready for snapshot", null)
                                    return@onMethodCall
                                }

                                val bitmap = try {
                                    Bitmap.createBitmap(
                                        viewWidth,
                                        viewHeight,
                                        Bitmap.Config.ARGB_8888
                                    )
                                } catch (oom: OutOfMemoryError) {
                                    Log.e(TAG, "snapshot OOM creating bitmap", oom)
                                    showFeaturePoints = wantShowFeaturePoints
                                    result.error("e", "Not enough memory for AR snapshot. Try Measure again.", null)
                                    return@onMethodCall
                                }

                                val handlerThread = HandlerThread("PixelCopier")
                                handlerThread.start()
                                var replied = false
                                fun replyOnce(block: () -> Unit) {
                                    if (replied) return
                                    replied = true
                                    try {
                                        block()
                                    } catch (e: Exception) {
                                        Log.e(TAG, "snapshot reply failed", e)
                                        try {
                                            result.error("e", e.message, null)
                                        } catch (_: Exception) {
                                        }
                                    } catch (oom: OutOfMemoryError) {
                                        Log.e(TAG, "snapshot reply OOM", oom)
                                        try {
                                            result.error("e", "Not enough memory for AR snapshot. Try Measure again.", null)
                                        } catch (_: Exception) {
                                        }
                                    }
                                }

                                Handler(context.mainLooper).postDelayed({
                                    replyOnce {
                                        try {
                                            bitmap.recycle()
                                        } catch (_: Exception) {
                                        }
                                        showFeaturePoints = wantShowFeaturePoints
                                        result.error("e", "AR snapshot timed out", null)
                                    }
                                }, 3500)

                                PixelCopy.request(
                                    arSceneView,
                                    bitmap,
                                    { copyResult: Int ->
                                        Log.d(TAG, "PIXELCOPY DONE result=$copyResult")
                                        val mainHandler = Handler(context.mainLooper)
                                        mainHandler.post {
                                            replyOnce {
                                                if (copyResult == PixelCopy.SUCCESS) {
                                                    val maxSide = 1280
                                                    val longest = maxOf(bitmap.width, bitmap.height)
                                                    val outBitmap = if (longest > maxSide) {
                                                        val scale = maxSide.toFloat() / longest.toFloat()
                                                        val tw = (bitmap.width * scale).toInt().coerceAtLeast(1)
                                                        val th = (bitmap.height * scale).toInt().coerceAtLeast(1)
                                                        val scaled = Bitmap.createScaledBitmap(bitmap, tw, th, true)
                                                        try {
                                                            bitmap.recycle()
                                                        } catch (_: Exception) {
                                                        }
                                                        scaled
                                                    } else {
                                                        bitmap
                                                    }

                                                    val stream = ByteArrayOutputStream()
                                                    outBitmap.compress(
                                                        Bitmap.CompressFormat.JPEG,
                                                        80,
                                                        stream
                                                    )
                                                    val data = stream.toByteArray()
                                                    try {
                                                        outBitmap.recycle()
                                                    } catch (_: Exception) {
                                                    }
                                                    showFeaturePoints = wantShowFeaturePoints
                                                    result.success(data)
                                                } else {
                                                    try {
                                                        bitmap.recycle()
                                                    } catch (_: Exception) {
                                                    }
                                                    showFeaturePoints = wantShowFeaturePoints
                                                    result.error(
                                                        "e",
                                                        "failed to take screenshot ($copyResult)",
                                                        null
                                                    )
                                                }
                                            }
                                            handlerThread.quitSafely()
                                        }
                                    },
                                    Handler(handlerThread.looper)
                                )
                            } catch (e: Exception) {
                                Log.e(TAG, "snapshot failed", e)
                                showFeaturePoints = wantShowFeaturePoints
                                result.error("e", e.message, null)
                            } catch (oom: OutOfMemoryError) {
                                Log.e(TAG, "snapshot OOM", oom)
                                showFeaturePoints = wantShowFeaturePoints
                                result.error("e", "Not enough memory for AR snapshot. Try Measure again.", null)
                            }
                        }
                        "dispose" -> {
                            dispose()
                            result.success(null)
                        }
                        else -> {}
                    }
                }
            }
    private val onObjectMethodCall =
            object : MethodChannel.MethodCallHandler {
                override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                    Log.d(TAG, "AndroidARView onobjectmethodcall reveived a call!")
                    when (call.method) {
                        "init" -> {
                            // objectManagerChannel.invokeMethod("onError", listOf("ObjectTEST from
                            // Android"))
                        }
                        "addNode" -> {
                            val dict_node: HashMap<String, Any>? = call.arguments as? HashMap<String, Any>
                            dict_node?.let{
                                addNode(it).thenAccept{status: Boolean ->
                                    result.success(status)
                                }.exceptionally { throwable ->
                                    result.error("e", throwable.message, throwable.stackTrace)
                                    null
                                }
                            }
                        }
                        "addNodeToPlaneAnchor" -> {
                            val dict_node: HashMap<String, Any>? = call.argument<HashMap<String, Any>>("node")
                            val dict_anchor: HashMap<String, Any>? = call.argument<HashMap<String, Any>>("anchor")
                            if (dict_node != null && dict_anchor != null) {
                                addNode(dict_node, dict_anchor).thenAccept{status: Boolean ->
                                    result.success(status)
                                }.exceptionally { throwable ->
                                    result.error("e", throwable.message, throwable.stackTrace)
                                    null
                                }
                            } else {
                                result.success(false)
                            }

                        }
                        "removeNode" -> {
                            val nodeName: String? = call.argument<String>("name")
                            nodeName?.let{
                                if (transformationSystem.selectedNode?.name == nodeName){
                                    transformationSystem.selectNode(null)
                                    keepNodeSelected = true
                                }
                                val node = arSceneView.scene.findByName(nodeName)
                                node?.let{
                                    arSceneView.scene.removeChild(node)
                                    result.success(null)
                                }
                            }
                        }
                        "transformationChanged" -> {
                            val nodeName: String? = call.argument<String>("name")
                            val newTransformation: ArrayList<Double>? = call.argument<ArrayList<Double>>("transformation")
                            nodeName?.let{ name ->
                                newTransformation?.let{ transform ->
                                    transformNode(name, transform)
                                    result.success(null)
                                }
                            }
                        }
                        else -> {}
                    }
                }
            }
    private val onAnchorMethodCall =
            object : MethodChannel.MethodCallHandler {
                override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                    when (call.method) {
                        "addAnchor" -> {
                            val anchorType: Int? = call.argument<Int>("type")
                            if (anchorType != null){
                                when(anchorType) {
                                    0 -> { // Plane Anchor
                                        val transform: ArrayList<Double>? = call.argument<ArrayList<Double>>("transformation")
                                        val name: String? = call.argument<String>("name")
                                        if ( name != null && transform != null){
                                            result.success(addPlaneAnchor(transform, name))
                                        } else {
                                            result.success(false)
                                        }

                                    }
                                    else -> result.success(false)
                                }
                            } else {
                                result.success(false)
                            }
                        }
                        "removeAnchor" -> {
                            val anchorName: String? = call.argument<String>("name")
                            anchorName?.let{ name ->
                                removeAnchor(name)
                            }
                        }
                        "initGoogleCloudAnchorMode" -> {
                            if (arSceneView.session != null) {
                                val config = Config(arSceneView.session)
                                config.cloudAnchorMode = Config.CloudAnchorMode.ENABLED
                                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                                config.focusMode = Config.FocusMode.AUTO
                                arSceneView.session?.configure(config)

                                cloudAnchorHandler = CloudAnchorHandler(arSceneView.session!!)
                            } else {
                                sessionManagerChannel.invokeMethod("onError", listOf("Error initializing cloud anchor mode: Session is null"))
                            }
                        }
                        "uploadAnchor" ->  {
                            val anchorName: String? = call.argument<String>("name")
                            val ttl: Int? = call.argument<Int>("ttl")
                            anchorName?.let {
                                val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                if (ttl != null) {
                                    cloudAnchorHandler.hostCloudAnchorWithTtl(anchorName, anchorNode!!.anchor, cloudAnchorUploadedListener(), ttl!!)
                                } else {
                                    cloudAnchorHandler.hostCloudAnchor(anchorName, anchorNode!!.anchor, cloudAnchorUploadedListener())
                                }
                                //Log.d(TAG, "---------------- HOSTING INITIATED ------------------")
                                result.success(true)
                            }

                        }
                        "downloadAnchor" -> {
                            val anchorId: String? = call.argument<String>("cloudanchorid")
                            //Log.d(TAG, "---------------- RESOLVING INITIATED ------------------")
                            anchorId?.let {
                                cloudAnchorHandler.resolveCloudAnchor(anchorId, cloudAnchorDownloadedListener())
                            }
                        }
                        else -> {}
                    }
                }
            }

    override fun getView(): View {
        return arSceneView
    }

    override fun dispose() {
        // Destroy AR session
        Log.d(TAG, "dispose called")
        try {
            onPause()
            onDestroy()
            ArSceneView.destroyAllResources()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    init {

        Log.d(TAG, "Initializing AndroidARView")
        viewContext = context

        arSceneView = ArSceneView(context)

        setupLifeCycle(context)

        sessionManagerChannel.setMethodCallHandler(onSessionMethodCall)
        objectManagerChannel.setMethodCallHandler(onObjectMethodCall)
        anchorManagerChannel.setMethodCallHandler(onAnchorMethodCall)

        // Keep the selection visualizer invisible. The previous 0.7m white
        // cylinder looked like a fake floor marker and blocked the AR view.
        MaterialFactory.makeTransparentWithColor(context, Color(0f, 0f, 0f, 0f))
                .thenAccept { mat ->
                    val tiny = ShapeFactory.makeCylinder(0.001f, 0.001f, Vector3.zero(), mat)
                    tiny.collisionShape = null
                    tiny.isShadowCaster = false
                    tiny.isShadowReceiver = false
                    footprintSelectionVisualizer.footprintRenderable = tiny
                }

        transformationSystem =
                TransformationSystem(
                        activity.resources.displayMetrics,
                        footprintSelectionVisualizer)

        onResume() // call onResume once to setup initial session
        // TODO: find out why this does not happen automatically
    }

    private fun setupLifeCycle(context: Context) {
        activityLifecycleCallbacks =
                object : Application.ActivityLifecycleCallbacks {
                    override fun onActivityCreated(
                            activity: Activity,
                            savedInstanceState: Bundle?
                    ) {
                        Log.d(TAG, "onActivityCreated")
                    }

                    override fun onActivityStarted(activity: Activity) {
                        Log.d(TAG, "onActivityStarted")
                    }

                    override fun onActivityResumed(activity: Activity) {
                        Log.d(TAG, "onActivityResumed")
                        onResume()
                    }

                    override fun onActivityPaused(activity: Activity) {
                        Log.d(TAG, "onActivityPaused")
                        onPause()
                    }

                    override fun onActivityStopped(activity: Activity) {
                        Log.d(TAG, "onActivityStopped")
                        // onStopped()
                        onPause()
                    }

                    override fun onActivitySaveInstanceState(
                            activity: Activity,
                            outState: Bundle
                    ) {}

                    override fun onActivityDestroyed(activity: Activity) {
                        Log.d(TAG, "onActivityDestroyed")
//                        onPause()
//                        onDestroy()
                    }
                }

        activity.application.registerActivityLifecycleCallbacks(this.activityLifecycleCallbacks)
    }

    fun onResume() {
        // Create session if there is none
        if (arSceneView.session == null) {
            Log.d(TAG, "ARSceneView session is null. Trying to initialize")
            try {
                var session: Session?
                if (ArCoreApk.getInstance().requestInstall(activity, mUserRequestedInstall) ==
                        ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                    Log.d(TAG, "Install of ArCore APK requested")
                    session = null
                } else {
                    session = Session(activity)
                }

                if (session == null) {
                    // Ensures next invocation of requestInstall() will either return
                    // INSTALLED or throw an exception.
                    mUserRequestedInstall = false
                    return
                } else {
                    applySessionConfig(session)
                    arSceneView.setupSession(session)
                }
            } catch (ex: UnavailableUserDeclinedInstallationException) {
                // Display an appropriate message to the user zand return gracefully.
                Toast.makeText(
                        activity,
                        "TODO: handle exception " + ex.localizedMessage,
                        Toast.LENGTH_LONG)
                        .show()
                return
            } catch (ex: UnavailableArcoreNotInstalledException) {
                Toast.makeText(activity, "Please install ARCore", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableApkTooOldException) {
                Toast.makeText(activity, "Please update ARCore", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableSdkTooOldException) {
                Toast.makeText(activity, "Please update this app", Toast.LENGTH_LONG).show()
                return
            } catch (ex: UnavailableDeviceNotCompatibleException) {
                Toast.makeText(activity, "This device does not support AR", Toast.LENGTH_LONG)
                        .show()
                return
            } catch (e: Exception) {
                Toast.makeText(activity, "Failed to create AR session", Toast.LENGTH_LONG).show()
                return
            }
        }

        try {
            arSceneView.resume()
        } catch (ex: CameraNotAvailableException) {
            Log.d(TAG, "Unable to get camera" + ex)
            // First AR open often races the camera — retry once before giving up.
            try {
                Thread.sleep(400)
                arSceneView.resume()
                return
            } catch (retryEx: Exception) {
                Log.e(TAG, "AR camera retry failed", retryEx)
            }
            try {
                Toast.makeText(
                    activity,
                    "Camera busy. Close other camera apps and try AR again.",
                    Toast.LENGTH_LONG
                ).show()
            } catch (_: Exception) {
            }
            try {
                sessionManagerChannel.invokeMethod(
                    "onError",
                    "Camera not available for AR. Please try again."
                )
            } catch (_: Exception) {
            }
            return
        } catch (e : Exception){
            return
        }
    }

    fun onPause() {
        // hide instructions view if no longer required
        if (showAnimatedGuide){
            val view = activity.findViewById(R.id.content) as ViewGroup
            view.removeView(animatedGuide)
            showAnimatedGuide = false
        }
        arSceneView.pause()
    }

    fun onDestroy() {
        try {
            arSceneView.session?.close()
            arSceneView.destroy()
            arSceneView.scene?.removeOnUpdateListener(sceneUpdateListener)
            arSceneView.scene?.removeOnPeekTouchListener(onNodeTapListener)
        }catch (e : Exception){
            e.printStackTrace();
        }
    }

    private fun initializeARView(call: MethodCall, result: MethodChannel.Result) {
        // Unpack call arguments
        val argShowFeaturePoints: Boolean? = call.argument<Boolean>("showFeaturePoints")
        val argPlaneDetectionConfig: Int? = call.argument<Int>("planeDetectionConfig")
        val argShowPlanes: Boolean? = call.argument<Boolean>("showPlanes")
        val argCustomPlaneTexturePath: String? = call.argument<String>("customPlaneTexturePath")
        val argShowWorldOrigin: Boolean? = call.argument<Boolean>("showWorldOrigin")
        val argHandleTaps: Boolean? = call.argument<Boolean>("handleTaps")
        val argHandleRotation: Boolean? = call.argument<Boolean>("handleRotation")
        val argHandlePans: Boolean? = call.argument<Boolean>("handlePans")
        val argShowAnimatedGuide: Boolean? = call.argument<Boolean>("showAnimatedGuide")


        sceneUpdateListener = com.google.ar.sceneform.Scene.OnUpdateListener {
            frameTime: FrameTime -> onFrame(frameTime)
        }
        onNodeTapListener = com.google.ar.sceneform.Scene.OnPeekTouchListener { hitTestResult, motionEvent ->
            //if (hitTestResult.node != null){
                //transformationSystem.selectionVisualizer.applySelectionVisual(hitTestResult.node as TransformableNode)
                //transformationSystem.selectNode(hitTestResult.node as TransformableNode)
            //}
            if (hitTestResult.node != null && motionEvent?.action == MotionEvent.ACTION_DOWN) {
                objectManagerChannel.invokeMethod("onNodeTap", listOf(hitTestResult.node?.name))
            }
            transformationSystem.onTouch(
                hitTestResult,
                motionEvent
            )
        }

        arSceneView.scene?.addOnUpdateListener(sceneUpdateListener)
        arSceneView.scene?.addOnPeekTouchListener(onNodeTapListener)


        // Configure Plane scanning guide
        if (argShowAnimatedGuide == true) { // explicit comparison necessary because of nullable type
            showAnimatedGuide = true
            val view = activity.findViewById(R.id.content) as ViewGroup
            animatedGuide = activity.layoutInflater.inflate(com.google.ar.sceneform.ux.R.layout.sceneform_plane_discovery_layout, null)
            view.addView(animatedGuide)
        }

        // Configure feature points
        if (argShowFeaturePoints ==
                true) { // explicit comparison necessary because of nullable type
            arSceneView.scene.addChild(pointCloudNode)
            wantShowFeaturePoints = true
            showFeaturePoints = true
            modelBuilder.ensureFeaturePointRenderable(viewContext)
        } else {
            wantShowFeaturePoints = false
            showFeaturePoints = false
            clearFeaturePointChildren()
            pointCloudNode.setParent(null)
        }

        pendingPlaneFindingMode = when (argPlaneDetectionConfig) {
            1 -> Config.PlaneFindingMode.HORIZONTAL
            2 -> Config.PlaneFindingMode.VERTICAL
            3 -> Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
            else -> Config.PlaneFindingMode.DISABLED
        }
        val session = arSceneView.session
        if (session == null) {
            Log.w(TAG, "initializeARView: session still null — will apply plane config on resume")
        } else {
            applySessionConfig(session)
        }

        // Configure whether or not detected planes should be shown.
        // White floor grid = Sceneform plane mesh (users call these "white dots").
        // Always boost visibility — default grid is nearly invisible on light tile floors.
        val showPlanes = argShowPlanes == true
        arSceneView.planeRenderer.isEnabled = showPlanes
        arSceneView.planeRenderer.isVisible = showPlanes
        if (showPlanes) {
            try {
                arSceneView.planeRenderer.material.thenAccept { material: Material ->
                    try {
                        material.setFloat(PlaneRenderer.MATERIAL_SPOTLIGHT_RADIUS, 100f)
                    } catch (_: Exception) {
                    }
                    try {
                        // Bright white plane mesh so the floor surface is obvious.
                        material.setFloat4(
                            PlaneRenderer.MATERIAL_COLOR,
                            Color(1.0f, 1.0f, 1.0f, 0.85f)
                        )
                    } catch (_: Exception) {
                        try {
                            material.setFloat3(PlaneRenderer.MATERIAL_COLOR, 1.0f, 1.0f, 1.0f)
                        } catch (_: Exception) {
                        }
                    }
                    try {
                        material.setFloat2(PlaneRenderer.MATERIAL_UV_SCALE, 8.0f, 8.0f)
                    } catch (_: Exception) {
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "planeRenderer material setup failed: ${e.message}")
            }
        }
        // Create custom plane renderer (use supplied texture & increase radius)
        argCustomPlaneTexturePath?.let {
            val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
            val key: String = loader.getLookupKeyForAsset(it)

            val sampler =
                    Texture.Sampler.builder()
                            .setMinFilter(Texture.Sampler.MinFilter.LINEAR)
                            .setWrapMode(Texture.Sampler.WrapMode.REPEAT)
                            .build()
            Texture.builder()
                    .setSource(viewContext, Uri.parse(key))
                    .setSampler(sampler)
                    .build()
                    .thenAccept { texture: Texture? ->
                        arSceneView.planeRenderer.material.thenAccept { material: Material ->
                            material.setTexture(PlaneRenderer.MATERIAL_TEXTURE, texture)
                            material.setFloat(PlaneRenderer.MATERIAL_SPOTLIGHT_RADIUS, 100f)
                        }
                    }
            // Set radius to render planes in
            arSceneView.scene.addOnUpdateListener { frameTime: FrameTime? ->
                val planeRenderer = arSceneView.planeRenderer
                planeRenderer.material.thenAccept { material: Material ->
                    material.setFloat(
                            PlaneRenderer.MATERIAL_SPOTLIGHT_RADIUS,
                            100f) // Sets the radius in which to visualize planes
                }
            }
        }

        // Configure world origin
        if (argShowWorldOrigin == true) {
            worldOriginNode = modelBuilder.makeWorldOriginNode(viewContext)
            arSceneView.scene.addChild(worldOriginNode)
        } else {
            worldOriginNode.setParent(null)
        }

        // Configure Tap handling
        if (argHandleTaps == true) { // explicit comparison necessary because of nullable type
            arSceneView.scene.setOnTouchListener{ hitTestResult: HitTestResult, motionEvent: MotionEvent? -> onTap(hitTestResult, motionEvent) }
        }

        // Configure gestures
        if (argHandleRotation ==
                true) { // explicit comparison necessary because of nullable type
            enableRotation = true
        } else {
            enableRotation = false
        }
        if (argHandlePans ==
                true) { // explicit comparison necessary because of nullable type
            enablePans = true
        } else {
            enablePans = false
        }

        result.success(null)
    }

    private fun onFrame(frameTime: FrameTime) {
        val frame = arSceneView.arFrame ?: return

        // hide instructions view if no longer required
        if (showAnimatedGuide){
            for (plane in frame.getUpdatedTrackables(Plane::class.java)) {
                if (plane.trackingState === TrackingState.TRACKING) {
                    val view = activity.findViewById(R.id.content) as ViewGroup
                    view.removeView(animatedGuide)
                    showAnimatedGuide = false
                    break
                }
            }
        }

        if (showFeaturePoints) {
            featurePointFrameCounter++
            if (featurePointFrameCounter % featurePointUpdateStride == 0) {
                updateFeaturePoints(frame)
            }
        } else {
            // Keep pool detached while dots are paused (e.g. during snapshot).
            if (pointCloudNode.children?.isNotEmpty() == true) {
                clearFeaturePointChildren()
            }
        }
        val updatedAnchors = frame.updatedAnchors
        // Notify the cloudManager of all the updates.
        if (this::cloudAnchorHandler.isInitialized) {cloudAnchorHandler.onUpdate(updatedAnchors)}

        if (keepNodeSelected && transformationSystem.selectedNode != null && transformationSystem.selectedNode!!.isTransforming){
            // If the selected node is currently transforming, we want to deselect it as soon as the transformation is done
            keepNodeSelected = false
        }
        if (!keepNodeSelected && transformationSystem.selectedNode != null && !transformationSystem.selectedNode!!.isTransforming){
            // once the transformation is done, deselect the node and allow selection of another node
            transformationSystem.selectNode(null)
            keepNodeSelected = true
        }
        if (!enablePans && !enableRotation){
            //unselect all nodes as we do not want the selection visualizer
            transformationSystem.selectNode(null)
        }

    }

    private fun clearFeaturePointChildren() {
        while (pointCloudNode.children?.size ?: 0 > 0) {
            pointCloudNode.children?.first()?.setParent(null)
        }
    }

    /**
     * Cheap, pooled feature-point visualization.
     * The old path allocated Material+Shape for every point every frame, which GC-thrashed
     * mid-range phones and caused ARCore tracking (and surface detection) to collapse.
     */
    private fun updateFeaturePoints(frame: Frame) {
        modelBuilder.ensureFeaturePointRenderable(viewContext)
        var pointCloud: PointCloud? = null
        try {
            pointCloud = frame.acquirePointCloud()
            val points = pointCloud.points ?: return
            val total = points.limit() / 4
            if (total <= 0) {
                clearFeaturePointChildren()
                return
            }

            // Prefer higher-confidence points; subsample if dense.
            val stride = if (total > maxFeaturePoints * 2) 2 else 1
            var shown = 0
            var index = 0
            while (index < total && shown < maxFeaturePoints) {
                val base = index * 4
                val confidence = points.get(base + 3)
                index += stride
                if (confidence < 0.35f) continue

                val x = points.get(base)
                val y = points.get(base + 1)
                val z = points.get(base + 2)

                val node = if (shown < featurePointPool.size) {
                    featurePointPool[shown]
                } else {
                    val created = modelBuilder.makeFeaturePointNode(viewContext, x, y, z)
                    featurePointPool.add(created)
                    created
                }
                modelBuilder.attachSharedRenderableIfReady(node)
                node.worldPosition = Vector3(x, y, z)
                if (node.parent !== pointCloudNode) {
                    node.setParent(pointCloudNode)
                }
                shown++
            }

            // Detach unused pooled nodes for this frame.
            for (i in shown until featurePointPool.size) {
                val extra = featurePointPool[i]
                if (extra.parent != null) {
                    extra.setParent(null)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "updateFeaturePoints: ${e.message}")
        } finally {
            try {
                pointCloud?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun applySessionConfig(session: Session) {
        val config = session.config
        config.planeFindingMode = pendingPlaneFindingMode
        config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
        config.focusMode = Config.FocusMode.AUTO
        try {
            // Height needs a real floor plane. Instant Placement fakes ~1.4m.
            config.instantPlacementMode = Config.InstantPlacementMode.DISABLED
        } catch (_: Exception) {
        }
        try {
            session.configure(config)
        } catch (e: Exception) {
            Log.e(TAG, "session.configure failed", e)
        }
    }

    private fun hitTestFloorSamples(): ArrayList<HashMap<String, Any>> {
        val w = arSceneView.width.toFloat()
        val h = arSceneView.height.toFloat()
        if (w <= 1f || h <= 1f) return ArrayList()
        val samples = arrayOf(
            Pair(w / 2f, h * 0.78f),
            Pair(w / 2f, h * 0.68f),
            Pair(w * 0.42f, h * 0.78f),
            Pair(w * 0.58f, h * 0.78f),
            Pair(w / 2f, h * 0.55f),
        )
        for ((x, y) in samples) {
            val hits = performFloorHitTest(x, y, 1.4f, false)
            if (hits.any { (it["type"] as? Int) == 1 }) {
                return hits
            }
        }
        return ArrayList()
    }

    private fun captureCameraJpeg(): ByteArray? {
        val frame = arSceneView.arFrame ?: return null
        if (frame.camera.trackingState != TrackingState.TRACKING) return null
        var image: Image? = null
        return try {
            image = frame.acquireCameraImage()
            yuv420ToJpeg(image, 80)
        } catch (e: Exception) {
            Log.w(TAG, "captureCameraJpeg: ${e.message}")
            null
        } finally {
            try {
                image?.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun yuv420ToJpeg(image: Image, quality: Int): ByteArray? {
        val nv21 = yuv420ToNv21(image) ?: return null
        val yuv = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
        val out = ByteArrayOutputStream()
        if (!yuv.compressToJpeg(Rect(0, 0, image.width, image.height), quality, out)) {
            return null
        }
        return out.toByteArray()
    }

    private fun yuv420ToNv21(image: Image): ByteArray? {
        val width = image.width
        val height = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val ySize = width * height
        val nv21 = ByteArray(ySize + ySize / 2)
        val yBuffer = yPlane.buffer
        val yRowStride = yPlane.rowStride
        val yPixelStride = yPlane.pixelStride
        var outputOffset = 0
        for (row in 0 until height) {
            val yRow = row * yRowStride
            for (col in 0 until width) {
                nv21[outputOffset++] = yBuffer.get(yRow + col * yPixelStride)
            }
        }
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride
        val chromaHeight = height / 2
        val chromaWidth = width / 2
        for (row in 0 until chromaHeight) {
            val uvRow = row * uvRowStride
            for (col in 0 until chromaWidth) {
                val uvIndex = uvRow + col * uvPixelStride
                nv21[outputOffset++] = vBuffer.get(uvIndex)
                nv21[outputOffset++] = uBuffer.get(uvIndex)
            }
        }
        return nv21
    }

    /**
     * Hit-test for floor placement: plane → feature point → (optional) Instant Placement.
     * Instant Placement is OFF by default for height calibration so we wait for a real
     * horizontal plane (white floor grid) instead of a fake 1.4m estimate.
     */
    private fun performFloorHitTest(
        x: Float,
        y: Float,
        approxDistanceMeters: Float,
        allowInstantPlacement: Boolean = false
    ): ArrayList<HashMap<String, Any>> {
        val frame = arSceneView.arFrame ?: return ArrayList()
        if (frame.camera.trackingState != TrackingState.TRACKING) {
            return ArrayList()
        }

        val allHitResults = frame.hitTest(x, y)
        val preferred = ArrayList<HitResult>()
        val fallback = ArrayList<HitResult>()

        for (hit in allHitResults) {
            when (val trackable = hit.trackable) {
                is Plane -> {
                    if (trackable.trackingState == TrackingState.TRACKING &&
                        trackable.type == Plane.Type.HORIZONTAL_UPWARD_FACING
                    ) {
                        // Early planes have tiny polygons — still use the hit.
                        preferred.add(hit)
                    }
                }
                is Point -> fallback.add(hit)
                is InstantPlacementPoint -> {
                    if (allowInstantPlacement) fallback.add(hit)
                }
            }
        }

        if (preferred.isEmpty() && fallback.isEmpty() && allowInstantPlacement) {
            try {
                val ipHits = frame.hitTestInstantPlacement(x, y, approxDistanceMeters)
                fallback.addAll(ipHits)
            } catch (e: Exception) {
                Log.w(TAG, "hitTestInstantPlacement: ${e.message}")
            }
        }

        val ordered = if (preferred.isNotEmpty()) preferred else fallback
        return ArrayList(ordered.map { serializeHitResult(it) })
    }

    private fun addNode(dict_node: HashMap<String, Any>, dict_anchor: HashMap<String, Any>? = null): CompletableFuture<Boolean>{
        val completableFutureSuccess: CompletableFuture<Boolean> = CompletableFuture()

        try {
            when (dict_node["type"] as Int) {
                0 -> { // GLTF2 Model from Flutter asset folder
                    // Get path to given Flutter asset
                    val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
                    val key: String = loader.getLookupKeyForAsset(dict_node["uri"] as String)

                    // Add object to scene
                    modelBuilder.makeNodeFromGltf(viewContext, transformationSystem, objectManagerChannel, enablePans, enableRotation, dict_node["name"] as String, key, dict_node["transformation"] as ArrayList<Double>)
                            .thenAccept{node ->
                                val anchorName: String? = dict_anchor?.get("name") as? String
                                val anchorType: Int? = dict_anchor?.get("type") as? Int
                                if (anchorName != null && anchorType != null) {
                                    val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                    if (anchorNode != null) {
                                        anchorNode.addChild(node)
                                        completableFutureSuccess.complete(true)
                                    } else {
                                        completableFutureSuccess.complete(false)
                                    }
                                } else {
                                    arSceneView.scene.addChild(node)
                                    completableFutureSuccess.complete(true)
                                }
                                completableFutureSuccess.complete(false)
                            }
                            .exceptionally { throwable ->
                                // Pass error to session manager (this has to be done on the main thread if this activity)
                                val mainHandler = Handler(viewContext.mainLooper)
                                val runnable = Runnable {sessionManagerChannel.invokeMethod("onError", listOf("Unable to load renderable" +  dict_node["uri"] as String)) }
                                mainHandler.post(runnable)
                                completableFutureSuccess.completeExceptionally(throwable)
                                null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                            }
                }
                1 -> { // GLB Model from the web
                    modelBuilder.makeNodeFromGlb(viewContext, transformationSystem, objectManagerChannel, enablePans, enableRotation, dict_node["name"] as String, dict_node["uri"] as String, dict_node["transformation"] as ArrayList<Double>)
                            .thenAccept{node ->
                                val anchorName: String? = dict_anchor?.get("name") as? String
                                val anchorType: Int? = dict_anchor?.get("type") as? Int
                                if (anchorName != null && anchorType != null) {
                                    val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                    if (anchorNode != null) {
                                        anchorNode.addChild(node)
                                        completableFutureSuccess.complete(true)
                                    } else {
                                        completableFutureSuccess.complete(false)
                                    }
                                } else {
                                    arSceneView.scene.addChild(node)
                                    completableFutureSuccess.complete(true)
                                }
                                completableFutureSuccess.complete(false)
                            }
                            .exceptionally { throwable ->
                                // Pass error to session manager (this has to be done on the main thread if this activity)
                                val mainHandler = Handler(viewContext.mainLooper)
                                val runnable = Runnable {sessionManagerChannel.invokeMethod("onError", listOf("Unable to load renderable" +  dict_node["uri"] as String)) }
                                mainHandler.post(runnable)
                                completableFutureSuccess.completeExceptionally(throwable)
                                null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                            }
                }
                2 -> { // fileSystemAppFolderGLB
                    val documentsPath = viewContext.getApplicationInfo().dataDir
                    val assetPath = documentsPath + "/app_flutter/" + dict_node["uri"] as String

                    modelBuilder.makeNodeFromGlb(viewContext, transformationSystem, objectManagerChannel, enablePans, enableRotation, dict_node["name"] as String, assetPath as String, dict_node["transformation"] as ArrayList<Double>) //
                            .thenAccept{node ->
                                val anchorName: String? = dict_anchor?.get("name") as? String
                                val anchorType: Int? = dict_anchor?.get("type") as? Int
                                if (anchorName != null && anchorType != null) {
                                    val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                    if (anchorNode != null) {
                                        anchorNode.addChild(node)
                                        completableFutureSuccess.complete(true)
                                    } else {
                                        completableFutureSuccess.complete(false)
                                    }
                                } else {
                                    arSceneView.scene.addChild(node)
                                    completableFutureSuccess.complete(true)
                                }
                                completableFutureSuccess.complete(false)
                            }
                            .exceptionally { throwable ->
                                // Pass error to session manager (this has to be done on the main thread if this activity)
                                val mainHandler = Handler(viewContext.mainLooper)
                                val runnable = Runnable {sessionManagerChannel.invokeMethod("onError", listOf("Unable to load renderable " +  dict_node["uri"] as String)) }
                                mainHandler.post(runnable)
                                completableFutureSuccess.completeExceptionally(throwable)
                                null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                            }
                }
                3 -> { //fileSystemAppFolderGLTF2
                    // Get path to given Flutter asset
                    val documentsPath = viewContext.getApplicationInfo().dataDir
                    val assetPath = documentsPath + "/app_flutter/" + dict_node["uri"] as String

                    // Add object to scene
                    modelBuilder.makeNodeFromGltf(viewContext, transformationSystem, objectManagerChannel, enablePans, enableRotation, dict_node["name"] as String, assetPath, dict_node["transformation"] as ArrayList<Double>)
                            .thenAccept{node ->
                                val anchorName: String? = dict_anchor?.get("name") as? String
                                val anchorType: Int? = dict_anchor?.get("type") as? Int
                                if (anchorName != null && anchorType != null) {
                                    val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
                                    if (anchorNode != null) {
                                        anchorNode.addChild(node)
                                        completableFutureSuccess.complete(true)
                                    } else {
                                        completableFutureSuccess.complete(false)
                                    }
                                } else {
                                    arSceneView.scene.addChild(node)
                                    completableFutureSuccess.complete(true)
                                }
                                completableFutureSuccess.complete(false)
                            }
                            .exceptionally { throwable ->
                                // Pass error to session manager (this has to be done on the main thread if this activity)
                                val mainHandler = Handler(viewContext.mainLooper)
                                val runnable = Runnable {sessionManagerChannel.invokeMethod("onError", listOf("Unable to load renderable" +  dict_node["uri"] as String)) }
                                mainHandler.post(runnable)
                                completableFutureSuccess.completeExceptionally(throwable)
                                null // return null because java expects void return (in java, void has no instance, whereas in Kotlin, this closure returns a Unit which has one instance)
                            }
                }
                else -> {
                    completableFutureSuccess.complete(false)
                }
            }
        } catch (e: java.lang.Exception) {
            completableFutureSuccess.completeExceptionally(e)
        }

        return completableFutureSuccess
    }

    private fun transformNode(name: String, transform: ArrayList<Double>) {
        val node = arSceneView.scene.findByName(name)
        node?.let {
            val transformTriple = deserializeMatrix4(transform)
            it.localScale = transformTriple.first
            it.localPosition = transformTriple.second
            it.localRotation = transformTriple.third
            //it.worldScale = transformTriple.first
            //it.worldPosition = transformTriple.second
            //it.worldRotation = transformTriple.third
        }
    }

    private fun onTap(hitTestResult: HitTestResult, motionEvent: MotionEvent?): Boolean {
        // CRITICAL: Do NOT return early when Sceneform hits a feature-point Node.
        // Users are told to "tap the floor dots" — those dots used to swallow the
        // ARCore hit-test and Flutter always got an empty result ("No surface detected").
        if (motionEvent == null || motionEvent.action != MotionEvent.ACTION_DOWN) {
            return false
        }

        val hits = performFloorHitTest(motionEvent.x, motionEvent.y, 1.4f, false)
        sessionManagerChannel.invokeMethod("onPlaneOrPointTap", hits)

        // Only notify node taps for *named* content nodes (not anonymous feature dots).
        val tappedName = hitTestResult.node?.name
        if (!tappedName.isNullOrEmpty() && hits.isEmpty()) {
            objectManagerChannel.invokeMethod("onNodeTap", listOf(tappedName))
        }
        return true
    }

    private fun addPlaneAnchor(transform: ArrayList<Double>, name: String): Boolean {
        return try {
            val position = floatArrayOf(deserializeMatrix4(transform).second.x, deserializeMatrix4(transform).second.y, deserializeMatrix4(transform).second.z)
            val rotation = floatArrayOf(deserializeMatrix4(transform).third.x, deserializeMatrix4(transform).third.y, deserializeMatrix4(transform).third.z, deserializeMatrix4(transform).third.w)
            val anchor: Anchor = arSceneView.session!!.createAnchor(Pose(position, rotation))
            val anchorNode = AnchorNode(anchor)
            anchorNode.name = name
            anchorNode.setParent(arSceneView.scene)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun removeAnchor(name: String) {
        val anchorNode = arSceneView.scene.findByName(name) as AnchorNode?
        anchorNode?.let{
            // Remove corresponding anchor from tracking
            anchorNode.anchor?.detach()
            // Remove children
            for (node in anchorNode.children) {
                if (transformationSystem.selectedNode?.name == node.name){
                    transformationSystem.selectNode(null)
                    keepNodeSelected = true
                }
                node.setParent(null)
            }
            // Remove anchor node
            anchorNode.setParent(null)
        }
    }

    private inner class cloudAnchorUploadedListener: CloudAnchorHandler.CloudAnchorListener {
        override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
            val cloudState = anchor!!.cloudAnchorState
            if (cloudState.isError) {
                Log.e(TAG, "Error uploading anchor, state $cloudState")
                sessionManagerChannel.invokeMethod("onError", listOf("Error uploading anchor, state $cloudState"))
                return
            }
            // Swap old an new anchor of the respective AnchorNode
            val anchorNode = arSceneView.scene.findByName(anchorName) as AnchorNode?
            val oldAnchor = anchorNode?.anchor
            anchorNode?.anchor = anchor
            oldAnchor?.detach()

            val args = HashMap<String, String?>()
            args["name"] = anchorName
            args["cloudanchorid"] = anchor.cloudAnchorId
            anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", args)
        }
    }

    private inner class cloudAnchorDownloadedListener: CloudAnchorHandler.CloudAnchorListener {
        override fun onCloudTaskComplete(anchorName: String?, anchor: Anchor?) {
            val cloudState = anchor!!.cloudAnchorState
            if (cloudState.isError) {
                Log.e(TAG, "Error downloading anchor, state $cloudState")
                sessionManagerChannel.invokeMethod("onError", listOf("Error downloading anchor, state $cloudState"))
                return
            }
            //Log.d(TAG, "---------------- RESOLVING SUCCESSFUL ------------------")
            val newAnchorNode = AnchorNode(anchor)
            // Register new anchor on the Flutter side of the plugin
            anchorManagerChannel.invokeMethod("onAnchorDownloadSuccess", serializeAnchor(newAnchorNode, anchor), object: MethodChannel.Result {
                override fun success(result: Any?) {
                    newAnchorNode.name = result.toString()
                    newAnchorNode.setParent(arSceneView.scene)
                    //Log.d(TAG, "---------------- REGISTERING ANCHOR SUCCESSFUL ------------------")
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    sessionManagerChannel.invokeMethod("onError", listOf("Error while registering downloaded anchor at the AR Flutter plugin: $errorMessage"))
                }

                override fun notImplemented() {
                    sessionManagerChannel.invokeMethod("onError", listOf("Error while registering downloaded anchor at the AR Flutter plugin"))
                }
            })
        }
    }

}


