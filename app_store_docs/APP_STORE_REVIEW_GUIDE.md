# App Review Notes & Submission Guide

This guide contains the exact notes, descriptions, and credentials to provide to Apple and Google reviewers in the **App Review Information / Test Notes** section of your store console. 

Providing clear instructions here is critical for **Clockwork BMI** to pass inspection, particularly regarding camera scans, government ID verification, and health tracking.

---

## 1. Demo Credentials (CRITICAL FOR REVIEWERS)

Both Apple and Google reviewers need to be able to log in without receiving an actual SMS OTP verification code.

### Reviewer Notes Template:
Copy and paste this text directly into the "Sign-in Information" or "App Review Notes" text box in the console:

```text
DEMO ACCOUNT FOR REVIEWERS:
To review the app, please use the following pre-configured test account. This account bypasses the SMS authentication requirements.

• Phone Number: +1 555-019-2834 (or whichever test number is configured in your Firebase Auth Sandbox)
• Verification Code (OTP): 123456 (or your configured Firebase verification code)
```

> **Developer Action Required:**
> In your Firebase Authentication Console, go to **Sign-in method** -> **Phone** -> **Phone numbers for testing (optional)**.
> Add a test phone number (e.g., `+1 555-019-2834`) and a test verification code (e.g., `123456`) so the reviewer can log in successfully.

---

## 2. Guideline 1.4.3 Compliance: Medical Disclaimers & Accuracy

Apple Guideline 1.4.3 states that apps that provide health/medical measurements must not cause physical harm or claim clinical diagnostics. 

### What to write in the "Notes" section:
```text
COMPLIANCE WITH GUIDELINE 1.4.3 (HEALTH & MEDICAL DISCLAIMERS):
Clockwork BMI is a general fitness tracking and wellness tool. It provides automated estimates of height, weight, and Body Mass Index (BMI) using camera-based AI pose estimation and segmentation. 

• The app does NOT provide medical advice, diagnosis, or clinical measurements.
• We have integrated prominent medical disclaimers at registration, on the main scanning page, and within the estimation results screen. 
• Users are clearly instructed that the calculations are algorithmic approximations and should consult a medical professional for any health evaluations.
• The EULA and Terms of Service (links provided) clearly establish these limitations of liability.
```

---

## 3. Guideline 5.1.1 Compliance: Identity Verification & Government ID

Apple is very strict about apps requesting government IDs (e.g. driver's licenses/passports) and may reject the app if the collection is not justified or secured.

### What to write in the "Notes" section:
```text
COMPLIANCE WITH GUIDELINE 5.1.1 & 1.2 (DATA COLLECTION & VERIFICATION):
The app includes a profile verification system that requires users to upload a photo of a government-issued ID. 

1. Purpose: This verification is required to verify the user’s age (confirming they are over 18), prevent fraudulent account creation, and ensure user profile integrity for account security.
2. Privacy & Security: All uploads are fully encrypted in transit using HTTPS (TLS 1.3) and stored in encrypted directories on our secure cloud database. 
3. Data Retention: The uploaded documents are reviewed solely for authentication and are purged/archived once verification is complete.
4. User Control: Users can delete their account and permanently erase all uploaded documentation and raw videos instantly by clicking "Delete Account" in the account settings.
```

---

## 4. Guidance on How to Perform a Test Scan (For Reviewers)

Since the app requires a body scan using the camera, reviewers need clear instructions on how to simulate a scan during testing (since they are often sitting at a desk).

### What to write in the "Notes" section:
```text
INSTRUCTIONS FOR TESTING THE CAMERA SCANNING FEATURE:
1. Log in using the test credentials provided.
2. Select "New Scan" from the dashboard.
3. Grant the app permission to access the device's camera.
4. The scan requires a clear view of a person standing. For testing in an office or review environment, you can point the device's camera at a printout or digital image/video of a full body standing, or stand up and step back 2-3 meters until the camera view captures your entire frame.
5. Follow the guiding pose indicators. The app will capture the landmarks, process them securely, and display the estimated results on the result screen.
```

---

## 5. Contact Information for App Review

Provide contact details in case the reviewer runs into issues or needs clarification:
* **Contact Name:** Clockwork Pharmacy Support
* **Contact Email:** admin@clockworkpharmacy.com (cc: clockworkbmi@gmail.com)
* **Contact Phone:** +44 7745430512 or +44 (0) 2089867560
