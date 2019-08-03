//
//  FPVViewController.swift
//  iOS-FPVDemo-Swift
//

import UIKit
import DJISDK
import DJIWidget
import Vision

class FPVViewController: UIViewController,  DJIVideoFeedListener, DJISDKManagerDelegate, DJICameraDelegate, VideoFrameProcessor {
    
    var isRecording : Bool!
    
    @IBOutlet var recordTimeLabel: UILabel!
    
    @IBOutlet var captureButton: UIButton!
    
    @IBOutlet var recordButton: UIButton!
    
    @IBOutlet var workModeSegmentControl: UISegmentedControl!
    
    @IBOutlet var fpvView: UIView!
    
    // YOLO specific vars
    let useVision = true
    let semaphore = DispatchSemaphore(value: 1)
    let yolo = YOLO()
    let drawBoundingBoxes = true
    var startTimes: [CFTimeInterval] = []
    var boundingBoxes = [BoundingBox]()
    var colors: [UIColor] = []
    // How many predictions we can do concurrently.
    static let maxInflightBuffers = 3
    var inflightBuffer = 0
    var requests = [VNCoreMLRequest]()
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    
        let camera = self.fetchCamera()
        if((camera != nil) && (camera?.delegate?.isEqual(self))!){
            camera?.delegate = nil
        }
        self.resetVideoPreview()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        DJISDKManager.registerApp(with: self)
        recordTimeLabel.isHidden = true
        
        setUpBoundingBoxes()
        setUpVision()
        
        // Add the bounding box layers to the UI, on top of the video preview.
        for box in self.boundingBoxes {
            box.addToLayer(self.fpvView.layer)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }

    func setupVideoPreviewer() {
       
        // So we can try and grab video frames
        DJIVideoPreviewer.instance().enableHardwareDecode = true
        DJIVideoPreviewer.instance()?.registFrameProcessor(self)
        
        DJIVideoPreviewer.instance().setView(self.fpvView)
        let product = DJISDKManager.product();
        
        //Use "SecondaryVideoFeed" if the DJI Product is A3, N3, Matrice 600, or Matrice 600 Pro, otherwise, use "primaryVideoFeed".
        if ((product?.model == DJIAircraftModelNameA3)
            || (product?.model == DJIAircraftModelNameN3)
            || (product?.model == DJIAircraftModelNameMatrice600)
            || (product?.model == DJIAircraftModelNameMatrice600Pro)){
            DJISDKManager.videoFeeder()?.secondaryVideoFeed.add(self, with: nil)
        }else{
            DJISDKManager.videoFeeder()?.primaryVideoFeed.add(self, with: nil)
        }
        DJIVideoPreviewer.instance().start()
    }
    
    func resetVideoPreview() {
        DJIVideoPreviewer.instance().unSetView()
        let product = DJISDKManager.product();
        
        //Use "SecondaryVideoFeed" if the DJI Product is A3, N3, Matrice 600, or Matrice 600 Pro, otherwise, use "primaryVideoFeed".
        if ((product?.model == DJIAircraftModelNameA3)
            || (product?.model == DJIAircraftModelNameN3)
            || (product?.model == DJIAircraftModelNameMatrice600)
            || (product?.model == DJIAircraftModelNameMatrice600Pro)){
            DJISDKManager.videoFeeder()?.secondaryVideoFeed.remove(self)
        }else{
            DJISDKManager.videoFeeder()?.primaryVideoFeed.remove(self)
        }
    }
    
    func fetchCamera() -> DJICamera? {
        let product = DJISDKManager.product()
        
        if (product == nil) {
            return nil
        }
        
        if (product!.isKind(of: DJIAircraft.self)) {
            return (product as! DJIAircraft).camera
        } else if (product!.isKind(of: DJIHandheld.self)) {
            return (product as! DJIHandheld).camera
        }
        return nil
    }
    
    func formatSeconds(seconds: UInt) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "mm:ss"
        return(dateFormatter.string(from: date))
    }
    
    func showAlertViewWithTitle(title: String, withMessage message: String) {
    
       let alert = UIAlertController.init(title: title, message: message, preferredStyle: UIAlertControllerStyle.alert)
       let okAction = UIAlertAction.init(title:"OK", style: UIAlertActionStyle.default, handler: nil)
      alert.addAction(okAction)
      self.present(alert, animated: true, completion: nil)
    
    }
    
    // DJISDKManagerDelegate Methods
    func productConnected(_ product: DJIBaseProduct?) {
        
        NSLog("Product Connected")
        
        if (product != nil) {
            let camera = self.fetchCamera()
            if (camera != nil) {
                camera!.delegate = self
            }
            self.setupVideoPreviewer()
        }
        
    }
    
    func productDisconnected() {
        
        NSLog("Product Disconnected")

        let camera = self.fetchCamera()
        if((camera != nil) && (camera?.delegate?.isEqual(self))!){
           camera?.delegate = nil
        }
        self.resetVideoPreview()
    }
    
    func appRegisteredWithError(_ error: Error?) {
        
        var message = "Register App Successed!"
        if (error != nil) {
            message = "Register app failed! Please enter your app key and check the network."
        } else {
            DJISDKManager.startConnectionToProduct()
        }
        
        self.showAlertViewWithTitle(title:"Register App", withMessage: message)
    }
    
    // DJICameraDelegate Method
    func camera(_ camera: DJICamera, didUpdate cameraState: DJICameraSystemState) {
        self.isRecording = cameraState.isRecording
        self.recordTimeLabel.isHidden = !self.isRecording
        
        self.recordTimeLabel.text = formatSeconds(seconds: cameraState.currentVideoRecordingTimeInSeconds)
        
        if (self.isRecording == true) {
            self.recordButton.setTitle("Stop Record", for: UIControlState.normal)
        } else {
            self.recordButton.setTitle("Start Record", for: UIControlState.normal)
        }
        
        //Update UISegmented Control's State
        if (cameraState.mode == DJICameraMode.shootPhoto) {
            self.workModeSegmentControl.selectedSegmentIndex = 0
        } else {
            self.workModeSegmentControl.selectedSegmentIndex = 1
        }
        
    }
    
    // DJIVideoFeedListener Method
    func videoFeed(_ videoFeed: DJIVideoFeed, didUpdateVideoData rawData: Data) {
        
        let videoData = rawData as NSData
        let videoBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: videoData.length)
        videoData.getBytes(videoBuffer, length: videoData.length)
        DJIVideoPreviewer.instance().push(videoBuffer, length: Int32(videoData.length))
    }
    
    // IBAction Methods
    @IBAction func captureAction(_ sender: UIButton) {
       
        let camera = self.fetchCamera()
        if (camera != nil) {
            camera?.setMode(DJICameraMode.shootPhoto, withCompletion: {(error) in
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1){
                    camera?.startShootPhoto(completion: { (error) in
                        if (error != nil) {
                            NSLog("Shoot Photo Error: " + String(describing: error))
                        }
                    })
                }
            })
        }
    }
    
    @IBAction func recordAction(_ sender: UIButton) {
        
        let camera = self.fetchCamera()
        if (camera != nil) {
            if (self.isRecording) {
                camera?.stopRecordVideo(completion: { (error) in
                    if (error != nil) {
                        NSLog("Stop Record Video Error: " + String(describing: error))
                    }
                })
            } else {
                camera?.startRecordVideo(completion: { (error) in
                    if (error != nil) {
                        NSLog("Start Record Video Error: " + String(describing: error))
                    }
                })
            }
        }
    }
    
    @IBAction func workModeSegmentChange(_ sender: UISegmentedControl) {
        
        let camera = self.fetchCamera()
        if (camera != nil) {
            if (sender.selectedSegmentIndex == 0) {
                camera?.setMode(DJICameraMode.shootPhoto,  withCompletion: { (error) in
                    if (error != nil) {
                        NSLog("Set ShootPhoto Mode Error: " + String(describing: error))
                    }
                })
                
            } else if (sender.selectedSegmentIndex == 1) {
                camera?.setMode(DJICameraMode.recordVideo,  withCompletion: { (error) in
                    if (error != nil) {
                        NSLog("Set RecordVideo Mode Error: " + String(describing: error))
                    }
                })
                
            }
        }
    }
    
    func videoProcessorEnabled() -> Bool {
        return true
    }
    
    func setUpBoundingBoxes() {
        for _ in 0..<YOLO.maxBoundingBoxes {
            boundingBoxes.append(BoundingBox())
        }
        
        // Make colors for the bounding boxes. There is one color for each class,
        // 20 classes in total.
        for r: CGFloat in [0.2, 0.4, 0.6, 0.8, 1.0] {
            for g: CGFloat in [0.3, 0.7] {
                for b: CGFloat in [0.4, 0.8] {
                    let color = UIColor(red: r, green: g, blue: b, alpha: 1)
                    colors.append(color)
                }
            }
        }
    }
    
    func setUpVision() {
        guard let visionModel = try? VNCoreMLModel(for: yolo.model.model) else {
            print("Error: could not create Vision model")
            return
        }
        
        for _ in 0..<FPVViewController.maxInflightBuffers {
            let request = VNCoreMLRequest(model: visionModel, completionHandler: visionRequestDidComplete)
            
            // NOTE: If you choose another crop/scale option, then you must also
            // change how the BoundingBox objects get scaled when they are drawn.
            // Currently they assume the full input image is used.
            request.imageCropAndScaleOption = .scaleFill
            requests.append(request)
        }
    }
    
    func visionRequestDidComplete(request: VNRequest, error: Error?) {
        if let observations = request.results as? [VNCoreMLFeatureValueObservation],
            let features = observations.first?.featureValue.multiArrayValue {
            let boundingBoxes = yolo.computeBoundingBoxes(features: features)
            //let elapsed = CACurrentMediaTime() - startTimes.remove(at: 0)
            showOnMainThread(boundingBoxes/*, elapsed*/)
        } else {
            print("BOGUS!")
        }
        
        self.semaphore.signal()
    }
    
    func showOnMainThread(_ boundingBoxes: [YOLO.Prediction]/*, _ elapsed: CFTimeInterval*/) {
        if drawBoundingBoxes {
            DispatchQueue.main.async {
                // For debugging, to make sure the resized CVPixelBuffer is correct.
                //var debugImage: CGImage?
                //VTCreateCGImageFromCVPixelBuffer(resizedPixelBuffer, nil, &debugImage)
                //self.debugImageView.image = UIImage(cgImage: debugImage!)
                self.show(predictions: boundingBoxes)
                
                //let fps = self.measureFPS()
                //self.timeLabel.text = String(format: "Elapsed %.5f seconds - %.2f FPS", elapsed, fps)
            }
        }
    }
    
    func show(predictions: [YOLO.Prediction]) {
        for i in 0..<predictions.count {
            if i < predictions.count {
                let prediction = predictions[i]
                
                // The predicted bounding box is in the coordinate space of the input
                // image, which is a square image of 416x416 pixels. We want to show it
                // on the video preview, which is as wide as the screen and has a 16:9
                // aspect ratio. The video preview also may be letterboxed at the top
                // and bottom.
                let width = view.bounds.width
                let height = width * 16 / 9
                let scaleX = width / CGFloat(YOLO.inputWidth)
                let scaleY = height / CGFloat(YOLO.inputHeight)
                let top = (view.bounds.height - height) / 2
                
                // Translate and scale the rectangle to our own coordinate system.
                var rect = prediction.rect
                rect.origin.x *= scaleX
                rect.origin.y *= scaleY
                rect.origin.y += top
                rect.size.width *= scaleX
                rect.size.height *= scaleY
                
                // Show the bounding box.
                let label = String(format: "%@ %.1f", labels[prediction.classIndex], prediction.score * 100)
                print("Prediction is \(label)")
                let color = colors[prediction.classIndex]
                boundingBoxes[i].show(frame: rect, label: label, color: color)
            } else {
                boundingBoxes[i].hide()
            }
        }
    }
    
    func videoProcessFrame(_ frame: UnsafeMutablePointer<VideoFrameYUV>!) {
        
        guard let pb = createPixelBuffer(fromFrame: frame.pointee) else {
            return
        }
        
        // The semaphore will block the capture queue and drop frames when
        // Core ML can't keep up with the camera.
        //semaphore.wait()
        
        // For better throughput, we want to schedule multiple prediction requests
        // in parallel. These need to be separate instances, and inflightBuffer is
        // the index of the current request.
        let inflightIndex = inflightBuffer
        inflightBuffer += 1
        if inflightBuffer >= FPVViewController.maxInflightBuffers {
            inflightBuffer = 0
        }
        
        if useVision {
            // This method should always be called from the same thread!
            // Ain't nobody likes race conditions and crashes.
            self.predictUsingVision(pixelBuffer: pb, inflightIndex: inflightIndex)
        } else {
            // For better throughput, perform the prediction on a concurrent
            // background queue instead of on the serial VideoCapture queue.
            DispatchQueue.global().async {
                //self.predict(pixelBuffer: pb, inflightIndex: inflightIndex)
            }
        }
        
        /*let request = VNCoreMLRequest(model: model) { (finishedReq, err) in
            
            guard let results = finishedReq.results as? [VNClassificationObservation] else { return }
            
            guard let firstObservation = results.first else { return }
            
            print(firstObservation.identifier, firstObservation.confidence)
            
        }
        
        try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([request])*/
        
        
        
        //print("video process frame is called. Height of buffer is \(CVPixelBufferGetHeight(pb)) ")
        
    }
    
    func predictUsingVision(pixelBuffer: CVPixelBuffer, inflightIndex: Int) {
        // Measure how long it takes to predict a single video frame. Note that
        // predict() can be called on the next frame while the previous one is
        // still being processed. Hence the need to queue up the start times.
        //startTimes.append(CACurrentMediaTime())
        
        // Vision will automatically resize the input image.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
        let request = requests[inflightIndex]
        
        // Because perform() will block until after the request completes, we
        // run it on a concurrent background queue, so that the next frame can
        // be scheduled in parallel with this one.
        DispatchQueue.global().async {
            try? handler.perform([request])
        }
    }
    
    func createPixelBuffer(fromFrame frame: VideoFrameYUV) -> CVPixelBuffer? {
        var initialPixelBuffer: CVPixelBuffer?
        let _: CVReturn = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height), kCVPixelFormatType_420YpCbCr8Planar, nil, &initialPixelBuffer)
        
        guard let pixelBuffer = initialPixelBuffer,
            CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess
            else {
                return nil
        }
        
        let yPlaneWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        
        let uPlaneWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        
        let vPlaneWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 2)
        let vPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 2)
        
        let yDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        memcpy(yDestination, frame.luma, yPlaneWidth * yPlaneHeight)
        
        let uDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        memcpy(uDestination, frame.chromaB, uPlaneWidth * uPlaneHeight)
        
        let vDestination = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2)
        memcpy(vDestination, frame.chromaR, vPlaneWidth * vPlaneHeight)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        return pixelBuffer
    }

}
