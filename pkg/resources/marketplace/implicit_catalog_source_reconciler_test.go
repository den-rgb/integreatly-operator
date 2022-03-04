package marketplace

import (
	"context"
	integreatlyv1alpha1 "github.com/integr8ly/integreatly-operator/apis/v1alpha1"
	moqclient "github.com/integr8ly/integreatly-operator/pkg/client"
	l "github.com/integr8ly/integreatly-operator/pkg/resources/logger"
	olmv1alpha1 "github.com/operator-framework/operator-lifecycle-manager/pkg/api/apis/operators/v1alpha1"
	operatorsv1alpha1 "github.com/operator-framework/operator-lifecycle-manager/pkg/api/apis/operators/v1alpha1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"os"
	k8sclient "sigs.k8s.io/controller-runtime/pkg/client"
	"testing"
)

func getBuildScheme() (*runtime.Scheme, error) {
	scheme := runtime.NewScheme()
	if err := integreatlyv1alpha1.SchemeBuilder.AddToScheme(scheme); err != nil {
		return nil, err
	}
	if err := olmv1alpha1.SchemeBuilder.AddToScheme(scheme); err != nil {
		return nil, err
	}
	return scheme, nil
}

func basicInstallation() *integreatlyv1alpha1.RHMI {
	return &integreatlyv1alpha1.RHMI{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "rhoam",
			Namespace: "redhat-rhoam-operator",
		},
	}
}

func getSubscription() *olmv1alpha1.Subscription {
	return &olmv1alpha1.Subscription{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "managed-api-sub",
			Namespace: "redhat-rhoam-operator",
			Labels: map[string]string{
				"operators.coreos.com/managed-api-service.redhat-rhoam-operator": "operators.coreos.com/managed-api-service.redhat-rhoam-operator",
			},
		},
		Spec: &olmv1alpha1.SubscriptionSpec{
			CatalogSource:          "redhat-rhoam-cs",
			CatalogSourceNamespace: "redhat-rhoam-operator",
		},
	}
}

func TestImplicitCatalogSourceReconcile(t *testing.T) {

	scheme, err := getBuildScheme()
	if err != nil {
		t.Fatal(err)
	}
	installation := basicInstallation()

	rhmiSubscription := getSubscription()

	cs := &operatorsv1alpha1.CatalogSource{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "redhat-rhoam-cs",
			Namespace: "redhat-rhoam-operator",
		},
	}

	cases := []struct {
		Name          string
		FakeClient    k8sclient.Client
		Log           l.Logger
		ExpectError   bool
		ExpectedError string
		VerifyCS      bool
	}{
		{
			Name:          "Test Reconcile",
			FakeClient:    moqclient.NewSigsClientMoqWithScheme(scheme, installation, rhmiSubscription, cs),
			Log:           l.NewLogger(),
			ExpectError:   false,
			ExpectedError: "",
			VerifyCS:      true,
		},
		{
			Name:          "Test Reconcile, no subscription",
			FakeClient:    moqclient.NewSigsClientMoqWithScheme(scheme, installation, cs),
			Log:           l.NewLogger(),
			ExpectError:   true,
			ExpectedError: "catalog source not found for implicit product installation type",
			VerifyCS:      false,
		},
		{
			Name:          "Test Reconcile, no catalog source",
			FakeClient:    moqclient.NewSigsClientMoqWithScheme(scheme, installation, cs),
			Log:           l.NewLogger(),
			ExpectError:   true,
			ExpectedError: "catalog source not found for implicit product installation type",
			VerifyCS:      false,
		},
	}

	os.Setenv("WATCH_NAMESPACE", "redhat-rhoam-operator")

	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			testReconciler, err := NewImplicitCatalogSourceReconciler(
				tc.Log,
				tc.FakeClient,
			)

			_, err = testReconciler.Reconcile(context.TODO(), "3scale")

			if err != nil && tc.ExpectError == false {
				t.Fatalf("unexpected error : '%v'", err)
			}

			if err != nil && tc.ExpectError == true && tc.ExpectedError != err.Error() {
				t.Fatalf("unexpected error : '%v', expected: %s", err, tc.ExpectedError)
			}

			if err == nil && tc.ExpectError == true {
				t.Fatalf("Expected error : '%s', but got none", tc.ExpectedError)
			}

			if tc.VerifyCS {
				if testReconciler.selfCatalogSource.Name != "redhat-rhoam-cs" || testReconciler.selfCatalogSource.Namespace != "redhat-rhoam-3scale-operator" {
					t.Fatal("Expected catalog source name: redhat-rhoam-cs, namespace: redhat-rhoam-3ccale-operator")
				}
			}

		})
	}
}
