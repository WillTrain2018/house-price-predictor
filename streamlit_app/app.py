import os
import socket

import requests
import streamlit as st

# For hostname and IP address
HOSTNAME = socket.gethostname()
IP_ADDRESS = socket.gethostbyname(HOSTNAME)

# API endpoint
API_URL = os.getenv("API_URL", "http://api:8000")

# Set the page configuration (must be the first Streamlit command)
st.set_page_config(
    page_title="House Price Predictor",
    layout="wide",
    initial_sidebar_state="collapsed"
)

# Add title and description
st.title("House Price Prediction")
st.markdown(
    """
    <p style="font-size: 18px; color: gray;">
        A simple MLOps demonstration project for real-time house price prediction
    </p>
    """,
    unsafe_allow_html=True,
)

# Create a two-column layout
col1, col2 = st.columns(2, gap="large")

# Input form
with col1:
    st.markdown('<div class="card">', unsafe_allow_html=True)

    # Example fields — replace with your actual model schema if different
    square_footage = st.slider("Square Footage", 500, 5000, 1800)
    bedrooms = st.slider("Bedrooms", 1, 8, 3)
    bathrooms = st.slider("Bathrooms", 1, 6, 2)
    age = st.slider("Age of House (years)", 0, 60, 15)

    submitted = st.button("Predict Price")

    if submitted:
        #payload = {
        #    "square_footage": square_footage,
        #    "bedrooms": bedrooms,
        #    "bathrooms": bathrooms,
        #    "age": age
        payload = {
            "sqft": square_footage,
            "bedrooms": bedrooms,
            "bathrooms": bathrooms,
            "location": "suburban",
            "year_built": 2023 - age,
            "condition": "Good",
        }
        
        try:
            response = requests.post(f"{API_URL}/predict", json=payload, timeout=30)
            response.raise_for_status()
            result = response.json()
            st.session_state["prediction"] = result
        except Exception as exc:
            st.error(f"Prediction failed: {exc}")

    st.markdown("</div>", unsafe_allow_html=True)

# Results section
with col2:
    st.subheader("Prediction Result")

    if "prediction" in st.session_state:
        st.json(st.session_state["prediction"])
    else:
        st.info("Enter values and click Predict Price.")

# Footer
st.markdown("<hr>", unsafe_allow_html=True)
st.markdown(
    f"""
    <div style="text-align: center; color: gray; margin-top: 20px;">
        <p><strong>Built for MLOps Bootcamp</strong></p>
        <p>by <a href="https://www.schoolofdevops.com" target="_blank">School of Devops</a></p>
        <p><strong>Hostname:</strong> {HOSTNAME}</p>
        <p><strong>IP Address:</strong> {IP_ADDRESS}</p>
    </div>
    """,
    unsafe_allow_html=True,
)