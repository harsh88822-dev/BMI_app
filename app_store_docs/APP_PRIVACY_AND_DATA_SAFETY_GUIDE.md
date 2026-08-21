# App Store Connect App Privacy & Google Play Data Safety Guide

When submitting **Clockwork BMI** to Apple App Store Connect and Google Play Console, you will be required to fill out questionnaire forms regarding your app's privacy practices. 

This guide details exactly how you should answer these questionnaires based on the app's features (Camera scan, Firebase backend, Government ID verification, and Push Notifications).

---

## Part 1: Apple App Store Connect - App Privacy Questionnaire

In App Store Connect, go to **App Privacy** in the left menu. You will need to select **"Get Started"** or **"Edit"** and answer which data types the app collects.

### 1. Data Collection Affirmation
* **Question:** Do you or your third-party partners collect data from this app?
* **Answer:** **Yes**

### 2. Identify the Data Types Collected
Select the checkboxes for the following data categories:

| Data Category | Specific Data Types | Purpose (How it is used) | Linked to User? | Used for Tracking? |
| :--- | :--- | :--- | :--- | :--- |
| **Contact Info** | • Name (First & Last)<br>• Phone Number | • App Functionality (Account setup)<br>• Account Management | **Yes** | **No** |
| **Health & Fitness** | • Health & Fitness Data (Ground-truth and estimated weight, height, calculated BMI) | • App Functionality (Providing estimations and logs) | **Yes** | **No** |
| **User Content** | • Photos or Videos (Video scans & Government ID uploads) | • App Functionality (ID verification, body scans) | **Yes** | **No** |
| **Identifiers** | • User ID (Firebase user uid)<br>• Device ID (Firebase cloud messaging tokens) | • App Functionality (Authenticating users, sending push notifications) | **Yes** | **No** |
| **Diagnostics** | • Crash Data<br>• Performance Data | • Analytics (Improving app stability) | **Yes** or **No** (Depending on if you associate crash logs with user IDs. Recommend: **No** if using anonymous Firebase Crashlytics) | **No** |

### 3. Detailed Setup for Selected Data Types
For each data type above, Apple will ask you to configure:

* **Name / Phone Number / User ID / Device ID / Health & Fitness / Photos or Videos:**
  - **Usage:** Select **App Functionality** and **Account Management**.
  - **Linked to User:** Select **Yes, this data is linked to the user's identity**.
  - **Tracking:** Select **No, we do not use this data for tracking purposes** (as you do not share it with third parties for cross-app advertising).

---

## Part 2: Google Play Console - Data Safety Form

In the Google Play Console, go to **App Content** -> **Data Safety**. You will need to fill out the form.

### 1. Data Collection and Security
* **Does your app collect or share any of the required user data types?**
  - **Yes**
* **Is all of the user data collected by your app encrypted in transit?**
  - **Yes** (All transmissions use HTTPS)
* **Do you provide a way for users to request that their data be deleted?**
  - **Yes** (You must provide the URL of your website's account deletion request page or details in this guide)

### 2. Data Types Declared

Select the following data types as **Collected** (and **NOT Shared**, since data is sent only to your own servers/processors):

#### A. Personal Info
* **Name** (First and Last name)
* **Phone number** (Registration phone number)
* **Other personal info** (Date of birth and gender)

#### B. Health and Fitness
* **Fitness info** (Estimated height, weight, BMI, and historical metrics)

#### C. Photos and Videos
* **Videos** (Body-scanning video files captured via camera)
* **Photos** (Government ID uploads for account verification)

#### D. App Info and Performance
* **Crash logs** (If using Firebase Crashlytics)
* **Diagnostics** (App responsiveness and latency metrics)

#### E. Device or Other IDs
* **Device or other IDs** (Firebase user uid / Firebase Cloud Messaging token)

---

### 3. Detail Questions for Each Data Type

For every data type you selected above, Google will ask specific questions. Configure them as follows:

* **Is this data collected, shared, or both?**
  - Select **Collected**. (Do NOT select Shared unless you sell/distribute it to third parties outside of standard service providers).
* **Is this data processed ephemerally?**
  - **No** (It is stored in the database for tracking user history). *Note: If government IDs are deleted immediately after review, you can mark Photos as ephemeral if you set up automatic purging, but it is safer to declare it as collected/stored securely.*
* **Is this data required for your app, or can users choose to prevent collection?**
  - Select **Data collection is required** (since registration, camera scans, and ID verification are core parts of the app workflow).
* **Why is this data collected?**
  - Select **App functionality** and **Account management**. (For Crash Logs, select **Analytics**).

---

## Part 3: Account Deletion URL Requirement

Both Apple and Google require developers to provide an **Account Deletion URL** where users can request data deletion even if the app is uninstalled. 

> **Developer Action Required:** 
> Create a simple page on your website (e.g., `https://www.yourdomain.com/delete-account`) that:
> 1. Explains that users can delete their accounts directly in the App (under Settings -> Delete Account).
> 2. Provides a simple contact form or mailto link (e.g., `support@yourdomain.com`) where users can submit a request with their phone number to have their account and associated video/ID files deleted manually.
> 3. Provide this URL in the App Store Connect and Google Play Console forms when prompted.
